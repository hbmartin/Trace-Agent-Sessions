import Foundation
import os

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode = "claude_code"
    case codex
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
}

public enum IndexScope: Int, Codable, CaseIterable, Sendable, Identifiable {
    case proseOnly
    case proseAndToolInvocations
    case everything

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .proseOnly: "Prose only"
        case .proseAndToolInvocations: "Prose + tool invocations"
        case .everything: "Everything"
        }
    }
}

public enum SourceFormat: String, Codable, Sendable {
    case claudeJSONL
    case codexJSONL
    case geminiJSON
    case geminiJSONL
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case system
    case reasoning
}

public struct SourceRoot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(agent.rawValue):\(url.path)" }
    public let agent: AgentKind
    public let url: URL
    public let isDefault: Bool
    private let cachedScanURL: URL
    private let cachedScanPath: TraceFileIO.CanonicalPath
    private let configuredComponents: [String]
    let hasSymlinkedComponent: Bool

    public init(agent: AgentKind, url: URL, isDefault: Bool = true) {
        // The configured path is the durable identity. Resolving it here made the
        // same symlink alternate identities as its target mounted and unmounted.
        let configuredURL = url.standardized
        let resolved = Self.resolveScanURL(configuredURL)
        self.init(
            agent: agent, configuredURL: configuredURL, isDefault: isDefault,
            frozenScanURL: resolved.url,
            frozenScanPath: TraceFileIO.canonicalPath(resolved.url.path),
            hasSymlinkedComponent: resolved.encounteredSymlink
        )
    }

    init(
        agent: AgentKind, url: URL, isDefault: Bool,
        frozenScanURL: URL, frozenCaseSensitive: Bool,
        hasSymlinkedComponent: Bool = false
    ) {
        let configuredURL = url.standardized
        let scanURL = frozenScanURL.standardized
        self.init(
            agent: agent, configuredURL: configuredURL, isDefault: isDefault,
            frozenScanURL: scanURL,
            frozenScanPath: .init(
                path: scanURL.path,
                comparisonKey: TraceFileIO.comparisonKey(
                    scanURL.path, caseSensitive: frozenCaseSensitive
                ),
                isCaseSensitive: frozenCaseSensitive
            ),
            hasSymlinkedComponent: hasSymlinkedComponent
        )
    }

    private init(
        agent: AgentKind, configuredURL: URL, isDefault: Bool,
        frozenScanURL: URL, frozenScanPath: TraceFileIO.CanonicalPath,
        hasSymlinkedComponent: Bool
    ) {
        self.agent = agent
        self.url = configuredURL
        self.isDefault = isDefault
        cachedScanURL = frozenScanURL
        cachedScanPath = frozenScanPath
        configuredComponents = Self.lexicalComponents(self.url.path)
        self.hasSymlinkedComponent = hasSymlinkedComponent
    }

    /// The stable path used for I/O during this source configuration. Every
    /// symlinked component is resolved lexically, including dangling targets.
    public var scanURL: URL { cachedScanURL }
    var scanPath: TraceFileIO.CanonicalPath { cachedScanPath }

    var rootScope: SourceRootScope {
        rootScope(in: mappingContext)
    }

    var rootSelectionDepth: Int {
        cachedScanURL.pathComponents.count
    }

    var mappingContext: SourceRootPathContext {
        let scanPath: TraceFileIO.CanonicalPath
        if FileManager.default.fileExists(atPath: url.path) {
            let live = TraceFileIO.canonicalPath(url.path)
            let liveFrozenKey = TraceFileIO.comparisonKey(
                live.path, caseSensitive: cachedScanPath.isCaseSensitive
            )
            scanPath = liveFrozenKey == cachedScanPath.comparisonKey ? live : cachedScanPath
        } else {
            scanPath = cachedScanPath
        }
        return SourceRootPathContext(
            scanPath: scanPath,
            configuredComponents: configuredComponents
        )
    }

    func rootScope(in context: SourceRootPathContext) -> SourceRootScope {
        SourceRootScope(
            scanPath: context.scanPath,
            relativeScope: RootRelativeScope(
                components: [], caseSensitive: context.scanPath.isCaseSensitive
            )
        )
    }

    /// Resolves a discovery path against the scan identity captured when this root
    /// was created. Configured-path containment is checked first so a later symlink
    /// repoint cannot reinterpret an alias path inside the old target.
    func scope(forRawPath rawPath: String) -> SourceRootScope? {
        scope(forRawPath: rawPath, in: mappingContext)
    }

    func scope(
        forRawPath rawPath: String, in context: SourceRootPathContext
    ) -> SourceRootScope? {
        let standardized = URL(fileURLWithPath: rawPath).standardized.path
        if standardized == url.path || standardized == cachedScanURL.path {
            return rootScope(in: context)
        }
        let lexical = Self.lexicalComponents(rawPath)
        let scanPath: TraceFileIO.CanonicalPath
        if Self.hasPrefix(
            Self.comparisonComponents(
                lexical, caseSensitive: context.scanPath.isCaseSensitive
            ),
            prefix: context.configuredComparisonComponents
        ) {
            var mapped = URL(fileURLWithPath: context.scanPath.path, isDirectory: true)
            for component in lexical.dropFirst(configuredComponents.count) {
                mapped.appendPathComponent(component)
            }
            scanPath = TraceFileIO.canonicalPath(mapped.path)
        } else {
            scanPath = TraceFileIO.canonicalPath(rawPath)
        }
        return scope(forScanPath: scanPath, in: context)
    }

    func reconciliationScope(forRawPath rawPath: String) -> SourceRootScope? {
        reconciliationScope(forRawPath: rawPath, in: mappingContext)
    }

    func reconciliationScope(
        forRawPath rawPath: String, in context: SourceRootPathContext
    ) -> SourceRootScope? {
        if let scope = scope(forRawPath: rawPath, in: context) { return scope }
        let lexical = Self.lexicalComponents(rawPath)
        let compared = Self.comparisonComponents(
            lexical, caseSensitive: context.scanPath.isCaseSensitive
        )
        if Self.hasPrefix(context.configuredComparisonComponents, prefix: compared)
            || Self.hasPrefix(context.scanComparisonComponents, prefix: compared) {
            return rootScope(in: context)
        }
        return nil
    }

    func scope(forScanPath path: TraceFileIO.CanonicalPath) -> SourceRootScope? {
        scope(forScanPath: path, in: mappingContext)
    }

    func scope(
        forScanPath path: TraceFileIO.CanonicalPath,
        in context: SourceRootPathContext
    ) -> SourceRootScope? {
        let components = Self.lexicalComponents(path.path)
        guard Self.hasPrefix(
            Self.comparisonComponents(
                components, caseSensitive: context.scanPath.isCaseSensitive
            ),
            prefix: context.scanComparisonComponents
        ) else { return nil }
        if components.count == context.scanComponents.count {
            return rootScope(in: context)
        }
        return SourceRootScope(
            scanPath: path,
            relativeScope: RootRelativeScope(
                components: Array(components.dropFirst(context.scanComponents.count)),
                caseSensitive: context.scanPath.isCaseSensitive
            )
        )
    }

    func scope(forRelativePath path: String) -> SourceRootScope? {
        let context = mappingContext
        guard let relativeScope = RootRelativeScope(
            persistedPath: path, caseSensitive: context.scanPath.isCaseSensitive
        ) else { return nil }
        if relativeScope.isRoot { return rootScope(in: context) }
        var mapped = URL(fileURLWithPath: context.scanPath.path, isDirectory: true)
        for component in relativeScope.components { mapped.appendPathComponent(component) }
        let canonical = TraceFileIO.canonicalPath(mapped.path)
        return scope(forScanPath: canonical, in: context) ?? rootScope(in: context)
    }

    /// Maps an indexed path back into this root without re-resolving symlinks.
    /// A failed mapping is intentionally conservative during subtree cleanup.
    func relativeScope(
        forStoredPath path: String, in context: SourceRootPathContext
    ) -> RootRelativeScope? {
        relativeScope(
            forStoredPath: path,
            scanComponents: context.scanComponents,
            caseSensitive: context.scanPath.isCaseSensitive
        )
    }

    private func relativeScope(
        forStoredPath path: String, scanComponents: [String], caseSensitive: Bool
    ) -> RootRelativeScope? {
        let scanComparisonComponents = Self.comparisonComponents(
            scanComponents, caseSensitive: caseSensitive
        )
        let components = Self.lexicalComponents(path)
        guard Self.hasPrefix(
            Self.comparisonComponents(
                components, caseSensitive: caseSensitive
            ),
            prefix: scanComparisonComponents
        ) else { return nil }
        return RootRelativeScope(
            components: Array(components.dropFirst(scanComponents.count)),
            caseSensitive: caseSensitive
        )
    }

    private static func lexicalComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path, isDirectory: true).standardized.pathComponents
    }

    private static func comparisonComponents(
        _ components: [String], caseSensitive: Bool
    ) -> [String] {
        components.map { TraceFileIO.comparisonKey($0, caseSensitive: caseSensitive) }
    }

    private static func hasPrefix(_ components: [String], prefix: [String]) -> Bool {
        guard components.count >= prefix.count else { return false }
        return zip(components, prefix).allSatisfy(==)
    }

    private enum CodingKeys: String, CodingKey { case agent, url, isDefault }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            agent: try values.decode(AgentKind.self, forKey: .agent),
            url: try values.decode(URL.self, forKey: .url),
            isDefault: try values.decode(Bool.self, forKey: .isDefault)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(agent, forKey: .agent)
        try values.encode(url, forKey: .url)
        try values.encode(isDefault, forKey: .isDefault)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.url == rhs.url && lhs.isDefault == rhs.isDefault
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(agent)
        hasher.combine(url)
        hasher.combine(isDefault)
    }

    public static func deduplicated(_ roots: [SourceRoot]) -> [SourceRoot] {
        var configuredKeys: Set<String> = []
        var scanKeys: Set<String> = []
        var kept: [SourceRoot] = []
        let ordered = roots.enumerated().sorted { lhs, rhs in
            if lhs.element.isDefault != rhs.element.isDefault {
                return lhs.element.isDefault
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for root in ordered {
            let configured = TraceFileIO.canonicalPath(root.url.path).comparisonKey
            let configuredKey = "\(root.agent.rawValue):\(configured)"
            let scanKey = "\(root.agent.rawValue):\(root.scanPath.comparisonKey)"
            guard !configuredKeys.contains(configuredKey), !scanKeys.contains(scanKey) else { continue }
            configuredKeys.insert(configuredKey)
            scanKeys.insert(scanKey)
            kept.append(root)
        }
        return kept
    }

    private static func resolveScanURL(_ configuredURL: URL) -> (url: URL, encounteredSymlink: Bool) {
        let manager = FileManager.default
        var pending = Array(configuredURL.standardized.pathComponents.dropFirst())
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        var visited: Set<String> = []
        var encounteredSymlink = false
        var hops = 0

        while !pending.isEmpty {
            candidate.appendPathComponent(pending.removeFirst())
            while hops < 32,
                  let destination = try? manager.destinationOfSymbolicLink(atPath: candidate.path) {
                let resolutionState = candidate.path + "\u{0}" + pending.joined(separator: "/")
                guard visited.insert(resolutionState).inserted else {
                    return (candidate.standardized, encounteredSymlink)
                }
                // macOS exposes stable top-level aliases such as /var ->
                // /private/var. They canonicalize path identity but do not make
                // an otherwise optional default root an unavailable mount.
                if candidate.pathComponents.count > 2 { encounteredSymlink = true }
                hops += 1
                let resolved = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : candidate.deletingLastPathComponent().appendingPathComponent(destination)
                pending = Array(resolved.standardized.pathComponents.dropFirst()) + pending
                candidate = URL(fileURLWithPath: "/", isDirectory: true)
            }
        }
        return (candidate.standardized, encounteredSymlink)
    }
}

struct SourceRootScope: Hashable, Sendable {
    let scanPath: TraceFileIO.CanonicalPath
    let relativeScope: RootRelativeScope
}

struct SourceRootPathContext: Hashable, Sendable {
    let scanPath: TraceFileIO.CanonicalPath
    let configuredComparisonComponents: [String]
    let scanComponents: [String]
    let scanComparisonComponents: [String]

    init(scanPath: TraceFileIO.CanonicalPath, configuredComponents: [String]) {
        self.scanPath = scanPath
        configuredComparisonComponents = configuredComponents.map {
            TraceFileIO.comparisonKey($0, caseSensitive: scanPath.isCaseSensitive)
        }
        scanComponents = URL(fileURLWithPath: scanPath.path, isDirectory: true)
            .standardized.pathComponents
        scanComparisonComponents = scanComponents.map {
            TraceFileIO.comparisonKey($0, caseSensitive: scanPath.isCaseSensitive)
        }
    }
}

struct RootRelativeScope: Hashable, Sendable {
    let path: String
    let components: [String]
    private let comparisonComponents: [String]
    let isCaseSensitive: Bool

    init(components: [String], caseSensitive: Bool) {
        self.components = components
        path = components.joined(separator: "/")
        comparisonComponents = components.map {
            TraceFileIO.comparisonKey($0, caseSensitive: caseSensitive)
        }
        isCaseSensitive = caseSensitive
    }

    init?(persistedPath: String, caseSensitive: Bool) {
        guard !persistedPath.hasPrefix("/") else { return nil }
        let components = persistedPath.isEmpty
            ? []
            : persistedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        self.init(components: components, caseSensitive: caseSensitive)
    }

    var comparisonKey: String { comparisonComponents.joined(separator: "/") }
    var isRoot: Bool { components.isEmpty }

    func contains(_ other: RootRelativeScope) -> Bool {
        guard isCaseSensitive == other.isCaseSensitive,
              comparisonComponents.count <= other.comparisonComponents.count
        else { return false }
        return zip(comparisonComponents, other.comparisonComponents).allSatisfy(==)
    }

    func intersects(_ other: RootRelativeScope) -> Bool {
        contains(other) || other.contains(self)
    }

    static func == (lhs: RootRelativeScope, rhs: RootRelativeScope) -> Bool {
        lhs.isCaseSensitive == rhs.isCaseSensitive
            && lhs.comparisonComponents == rhs.comparisonComponents
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(isCaseSensitive)
        hasher.combine(comparisonComponents)
    }
}

public struct DiscoveredSourceFile: Hashable, Sendable {
    public let agent: AgentKind
    public let root: URL
    public let url: URL
    public let format: SourceFormat
    let canonicalPath: TraceFileIO.CanonicalPath

    public init(agent: AgentKind, root: URL, url: URL, format: SourceFormat) {
        self.agent = agent
        self.root = root.standardized
        canonicalPath = TraceFileIO.canonicalPath(url.path)
        self.url = URL(fileURLWithPath: canonicalPath.path)
        self.format = format
    }
}

public struct IndexRecoveryWork: Sendable {
    public let filePaths: Set<String>
    public let reconciliationPaths: Set<String>

    public init(filePaths: Set<String> = [], reconciliationPaths: Set<String> = []) {
        self.filePaths = filePaths
        self.reconciliationPaths = reconciliationPaths
    }

    public var isEmpty: Bool { filePaths.isEmpty && reconciliationPaths.isEmpty }
}

public struct SourceFailureCounts: Equatable, Sendable {
    public let fileFailures: Int
    public let discoveryFailures: Int

    public init(fileFailures: Int = 0, discoveryFailures: Int = 0) {
        self.fileFailures = fileFailures
        self.discoveryFailures = discoveryFailures
    }
}

public struct SourceFingerprint: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationNanoseconds: Int64
    public let headHash: Data
    public let headLength: Int

    public init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationNanoseconds: Int64,
        headHash: Data,
        headLength: Int
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationNanoseconds = modificationNanoseconds
        self.headHash = headHash
        self.headLength = headLength
    }
}

public enum LocatorKind: String, Codable, Sendable {
    case byteRange = "byte_range"
    case keyedRecord = "keyed_record"
}

public struct RecordLocator: Codable, Hashable, Sendable {
    public let kind: LocatorKind
    public let offset: Int64?
    public let length: Int64?
    public let key: String?

    public static func byteRange(offset: Int64, length: Int64, key: String? = nil) -> Self {
        .init(kind: .byteRange, offset: offset, length: length, key: key)
    }

    public static func keyed(_ key: String) -> Self {
        .init(kind: .keyedRecord, offset: nil, length: nil, key: key)
    }
}

public struct MessageSections: Codable, Equatable, Sendable {
    public var prose: String
    public var toolInvocation: String
    public var toolOutput: String
    public var reasoning: String
    public var hasNonTextContent: Bool

    public init(
        prose: String = "",
        toolInvocation: String = "",
        toolOutput: String = "",
        reasoning: String = "",
        hasNonTextContent: Bool = false
    ) {
        self.prose = prose
        self.toolInvocation = toolInvocation
        self.toolOutput = toolOutput
        self.reasoning = reasoning
        self.hasNonTextContent = hasNonTextContent
    }

    public func indexedText(for scope: IndexScope) -> String {
        switch scope {
        case .proseOnly:
            prose
        case .proseAndToolInvocations:
            [prose, toolInvocation].filter { !$0.isEmpty }.joined(separator: "\n")
        case .everything:
            [prose, toolInvocation, toolOutput].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    public var flags: Int {
        (prose.isEmpty ? 0 : 1)
            | (toolInvocation.isEmpty && toolOutput.isEmpty ? 0 : 2)
            | (reasoning.isEmpty ? 0 : 4)
            | (hasNonTextContent ? 8 : 0)
    }

    public var preferredPreview: String {
        if !prose.isEmpty { return prose }
        if !toolInvocation.isEmpty { return toolInvocation }
        if !toolOutput.isEmpty { return toolOutput }
        return reasoning
    }

    private enum CodingKeys: String, CodingKey {
        case prose, toolInvocation, toolOutput, reasoning, hasNonTextContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prose = try container.decodeIfPresent(String.self, forKey: .prose) ?? ""
        toolInvocation = try container.decodeIfPresent(String.self, forKey: .toolInvocation) ?? ""
        toolOutput = try container.decodeIfPresent(String.self, forKey: .toolOutput) ?? ""
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        hasNonTextContent = try container.decodeIfPresent(Bool.self, forKey: .hasNonTextContent) ?? false
    }
}

public struct ParsedMessage: Sendable {
    public let sourceKey: String
    public let externalID: String?
    public let sessionExternalID: String
    public let cwd: String
    public let timestampMilliseconds: Int64
    public let role: MessageRole
    public let sections: MessageSections
    public let locator: RecordLocator
    public let model: String?
    public let isSidechain: Bool
    public let hasError: Bool
    public let toolName: String?
    public let usage: UsageObservation?

    public init(
        sourceKey: String,
        externalID: String?,
        sessionExternalID: String,
        cwd: String,
        timestampMilliseconds: Int64,
        role: MessageRole,
        sections: MessageSections,
        locator: RecordLocator,
        model: String? = nil,
        isSidechain: Bool = false,
        hasError: Bool = false,
        toolName: String? = nil,
        usage: UsageObservation? = nil
    ) {
        self.sourceKey = sourceKey
        self.externalID = externalID
        self.sessionExternalID = sessionExternalID
        self.cwd = cwd
        self.timestampMilliseconds = timestampMilliseconds
        self.role = role
        self.sections = sections
        self.locator = locator
        self.model = model
        self.isSidechain = isSidechain
        self.hasError = hasError
        self.toolName = toolName
        self.usage = usage
    }
}

public struct UsageObservation: Codable, Equatable, Sendable {
    public let dedupeKey: String
    public let model: String
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let cacheReadTokens: Int64?
    public let reasoningTokens: Int64?

    public init(
        dedupeKey: String,
        model: String,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil,
        cacheReadTokens: Int64? = nil,
        reasoningTokens: Int64? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum SessionEventKind: String, Sendable {
    case failed
    case aborted
}

public struct ParsedSessionEvent: Sendable {
    public let sourceKey: String
    public let sessionExternalID: String
    public let cwd: String
    public let timestampMilliseconds: Int64
    public let kind: SessionEventKind
    public var detail: String? = nil
    public var locator: RecordLocator? = nil
}

public struct ParsedUsageRecord: Sendable {
    public let sourceKey: String
    public let sessionExternalID: String
    public let cwd: String
    public let timestampMilliseconds: Int64
    public let isSidechain: Bool
    public let usage: UsageObservation
}

/// Context at the last committed byte boundary. The fallback stays fixed across appends.
public struct SourceReadContext: Sendable {
    public var sessionID: String?
    public var fallbackTimestampMilliseconds: Int64
    public var lastValidTimestampMilliseconds: Int64?

    public init(sessionID: String? = nil, fallbackTimestampMilliseconds: Int64,
                lastValidTimestampMilliseconds: Int64? = nil) {
        self.sessionID = sessionID
        self.fallbackTimestampMilliseconds = fallbackTimestampMilliseconds
        self.lastValidTimestampMilliseconds = lastValidTimestampMilliseconds
    }

    var timestampMilliseconds: Int64 {
        lastValidTimestampMilliseconds ?? fallbackTimestampMilliseconds
    }

    mutating func observeTimestamp(_ value: Any?) -> ParsedRecord? {
        guard let timestamp = JSONHelpers.explicitTimestampMilliseconds(value) else { return nil }
        lastValidTimestampMilliseconds = timestamp
        return .timestampContext(timestamp)
    }
}

public enum ParsedRecord: Sendable {
    case message(ParsedMessage)
    case usage(ParsedUsageRecord)
    case event(ParsedSessionEvent)
    case sessionContext(String)
    /// An explicit valid timestamp, including one on an otherwise ignored record.
    case timestampContext(Int64)
    case checkpoint(Int64)
}

public struct HydratedMessage: Sendable {
    public let role: MessageRole
    public let sections: MessageSections
    public let toolName: String?
    public let hasError: Bool
}

public struct ParseDiagnostic: Codable, Identifiable, Sendable {
    public let id: UUID
    public let agent: AgentKind
    public let path: String
    public let offset: Int64?
    public let message: String
    public let timestamp: Date

    public init(agent: AgentKind, path: String, offset: Int64?, message: String) {
        self.id = UUID()
        self.agent = agent
        self.path = path
        self.offset = offset
        self.message = message
        self.timestamp = Date()
    }
}

public enum SearchSort: String, Codable, CaseIterable, Sendable {
    case recency
    case relevance
}

public struct SearchFilters: Equatable, Sendable {
    public var agents: Set<AgentKind>
    public var projectCanonicalKey: String?
    public var fromMilliseconds: Int64?
    public var toMilliseconds: Int64?
    public var errorsOnly: Bool

    public init(
        agents: Set<AgentKind> = [],
        projectCanonicalKey: String? = nil,
        fromMilliseconds: Int64? = nil,
        toMilliseconds: Int64? = nil,
        errorsOnly: Bool = false
    ) {
        self.agents = agents
        self.projectCanonicalKey = projectCanonicalKey
        self.fromMilliseconds = fromMilliseconds
        self.toMilliseconds = toMilliseconds
        self.errorsOnly = errorsOnly
    }
}

public struct SearchCursor: Codable, Hashable, Sendable {
    public let rowID: Int64
    public let rank: Double?
    public let timestampMilliseconds: Int64?

    public init(rowID: Int64, rank: Double?, timestampMilliseconds: Int64? = nil) {
        self.rowID = rowID
        self.rank = rank
        self.timestampMilliseconds = timestampMilliseconds
    }
}

/// Identity of one committed content generation. Row IDs are valid only
/// within this generation, including when a reset later fails checkpointing.
public struct IndexContentGeneration: Hashable, Codable, Sendable {
    let value: String
    var databaseFamily: String { String(value.split(separator: ":").first ?? "") }
    func advanced() -> Self {
        .init(value: (databaseFamily.isEmpty ? UUID().uuidString : databaseFamily) + ":" + UUID().uuidString)
    }
    public func belongsToSameDatabase(as other: Self) -> Bool {
        databaseFamily == other.databaseFamily
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let id: Int64
    public let sessionID: Int64
    public let projectID: Int64
    public let projectCanonicalKey: String
    public let projectName: String
    public let sessionTitle: String
    public var sessionHasPlan: Bool = false
    public let agent: AgentKind
    public let role: MessageRole
    public let timestampMilliseconds: Int64
    public let prefix: String
    public let sourcePath: String
    public let rank: Double?
    public var contentGeneration: IndexContentGeneration? = nil
    public var navigationReference: SessionNavigationReference? = nil
}

public struct SearchPage: Sendable {
    public let results: [SearchResult]
    public let nextCursor: SearchCursor?
    public var contentGeneration: IndexContentGeneration? = nil

    public func uniqueResults(excluding existingIDs: Set<Int64>) -> [SearchResult] {
        var seen = existingIDs
        return results.filter { seen.insert($0.id).inserted }
    }
}

public struct ProjectSummary: Identifiable, Sendable {
    public let id: Int64
    public let canonicalKey: String
    public let displayName: String
    public let rootPath: String
    public let sessionCount: Int
    public let lastActivityMilliseconds: Int64
}

public struct SessionCursor: Hashable, Sendable {
    public let projectCanonicalKey: String?
    public let lastActivityMilliseconds: Int64
    public let sessionID: Int64

    public init(projectCanonicalKey: String?, lastActivityMilliseconds: Int64, sessionID: Int64) {
        self.projectCanonicalKey = projectCanonicalKey
        self.lastActivityMilliseconds = lastActivityMilliseconds
        self.sessionID = sessionID
    }
}

public struct SessionPage: Sendable {
    public let sessions: [SessionSummary]
    public let totalCount: Int
    public let nextCursor: SessionCursor?
    public var contentGeneration: IndexContentGeneration? = nil
}

public struct SessionListSnapshot: Sendable {
    public let sessions: [SessionSummary]
    public let totalCount: Int
    public let nextCursor: SessionCursor?
    public let pageCount: Int
    public var contentGeneration: IndexContentGeneration? = nil
}

public struct SidebarSnapshot: Sendable {
    public let projects: [ProjectSummary]
    public let recentSessions: [SessionSummary]
    public let sessionList: SessionListSnapshot
    public var contentGeneration: IndexContentGeneration? = nil
}

/// One logical anchor in a generation-fenced capture. Multiple requests may
/// identify the same session, for example its bookmark and a search target.
public struct NavigationCaptureRequest: Sendable {
    public let sessionID: Int64
    public let anchorMessageID: Int64?
    public let expectedReference: SessionNavigationReference?
    public let stableAnchor: SessionNavigationReference?
    /// Numeric fallback is eligible only in this exact content generation.
    public let anchorGeneration: IndexContentGeneration?
    public init(sessionID: Int64, anchorMessageID: Int64? = nil,
                expectedReference: SessionNavigationReference? = nil,
                stableAnchor: SessionNavigationReference? = nil,
                anchorGeneration: IndexContentGeneration? = nil) {
        self.sessionID = sessionID; self.anchorMessageID = anchorMessageID
        self.expectedReference = expectedReference; self.stableAnchor = stableAnchor
        self.anchorGeneration = anchorGeneration
    }
}

/// Immutable compressed radix nodes. A common path prefix is one edge rather
/// than one heap object and dictionary per UTF-8 byte.
private struct NavigationRank: Comparable, Sendable {
    let admission: UInt64
    var execution: UInt64 = 0
    static func < (a: Self, b: Self) -> Bool {
        a.admission == b.admission ? a.execution < b.execution : a.admission < b.admission
    }
}
private struct NavigationFact: Sendable { let rank: NavigationRank; let covered: Bool }
private final class NavigationScopeIndex: Sendable {
    let segment: [UInt8]
    let value: NavigationFact?
    let children: [UInt8: NavigationScopeIndex]
    let maximum: NavigationRank?
    let minimumAdmission: UInt64?
    let hasUncovered: Bool
    let counts: (nodes: Int, facts: Int)
    init(segment: [UInt8] = [], value: NavigationFact? = nil, children: [UInt8: NavigationScopeIndex] = [:]) {
        self.segment = segment; self.value = value; self.children = children
        maximum = ([value?.rank].compactMap { $0 } + children.values.compactMap(\.maximum)).max()
        minimumAdmission = ([value?.rank.admission].compactMap { $0 } + children.values.compactMap(\.minimumAdmission)).min()
        hasUncovered = value?.covered == false || children.values.contains { $0.hasUncovered }
        counts = (1 + children.values.reduce(0) { $0 + $1.counts.nodes },
            (value == nil ? 0 : 1) + children.values.reduce(0) { $0 + $1.counts.facts })
    }
    private static func node(_ segment: [UInt8], _ value: NavigationFact?, _ children: [UInt8: NavigationScopeIndex]) -> NavigationScopeIndex {
        if value == nil, children.count == 1, let child = children.values.first {
            return .init(segment: segment + child.segment, value: child.value, children: child.children)
        }
        return .init(segment: segment, value: value, children: children)
    }
    func visit(_ prefix: [UInt8] = [], _ body: ([UInt8], NavigationFact) -> Void) {
        let path = prefix + segment
        if let value { body(path, value) }
        for child in children.values { child.visit(path, body) }
    }
    func latest(_ key: [UInt8]) -> NavigationFact? {
        var node = self, position = 0, result: NavigationFact?
        while key.count - position >= node.segment.count,
              key[position..<(position + node.segment.count)].elementsEqual(node.segment) {
            position += node.segment.count
            if let value = node.value, result.map({ $0.rank <= value.rank }) ?? true { result = value }
            guard position < key.count, let next = node.children[key[position]] else { break }
            node = next
        }
        return result
    }
    private func subtree(_ key: [UInt8]) -> NavigationScopeIndex? {
        var node = self, position = 0
        while true {
            let count = min(key.count - position, node.segment.count)
            guard key[position..<(position + count)].elementsEqual(node.segment.prefix(count)) else { return nil }
            position += count
            if position == key.count { return node }
            guard count == node.segment.count, let next = node.children[key[position]] else { return nil }
            node = next
        }
    }
    func maximumIntersecting(_ key: [UInt8]) -> NavigationRank? {
        [latest(key)?.rank, subtree(key)?.maximum].compactMap { $0 }.max()
    }
    func fullyCovered(_ key: [UInt8], through admission: UInt64) -> Bool {
        guard let inherited = latest(key), inherited.covered, inherited.rank.admission >= admission else { return false }
        guard let child = subtree(key) else { return true }
        return !child.hasUncovered && (child.minimumAdmission.map { $0 >= admission } ?? true)
    }
    private func retaining(after rank: NavigationRank) -> NavigationScopeIndex? {
        guard maximum.map({ $0 > rank }) == true else { return nil }
        return Self.node(segment, value.flatMap { $0.rank > rank ? $0 : nil },
            children.compactMapValues { $0.retaining(after: rank) })
    }
    func setting(_ key: [UInt8], _ fact: NavigationFact, at position: Int = 0) -> NavigationScopeIndex {
        if position == 0, let inherited = latest(key) {
            if inherited.rank > fact.rank { return self }
            if inherited.rank == fact.rank, inherited.covered == fact.covered,
               subtree(key)?.hasUncovered != true { return self }
        }
        var shared = 0
        while shared < segment.count, position + shared < key.count, segment[shared] == key[position + shared] { shared += 1 }
        if shared < segment.count {
            let old = Self.node(Array(segment.dropFirst(shared)), value, children)
            var branches: [UInt8: NavigationScopeIndex] = [old.segment[0]: old]
            let remainder = Array(key.dropFirst(position + shared))
            if remainder.isEmpty { return Self.node(Array(segment.prefix(shared)), fact, branches.compactMapValues { $0.retaining(after: fact.rank) }) }
            branches[remainder[0]] = .init(segment: remainder, value: fact)
            return Self.node(Array(segment.prefix(shared)), nil, branches)
        }
        let position = position + shared
        if position == key.count {
            if let value, value.rank > fact.rank { return self }
            return Self.node(segment, fact, children.compactMapValues { $0.retaining(after: fact.rank) })
        }
        var branches = children
        let byte = key[position]
        if let child = branches[byte] { branches[byte] = child.setting(key, fact, at: position) }
        else { branches[byte] = .init(segment: Array(key.dropFirst(position)), value: fact) }
        return Self.node(segment, value, branches)
    }

}

private func navigationAbsoluteKey(_ comparisonKey: String) -> [UInt8] {
    Array((comparisonKey == "/" ? "/" : comparisonKey + "/").utf8)
}

/// Accepted source coverage. Old snapshots remain immutable while incremental
/// merges copy only affected scope prefixes, not the retained file dictionary.
public struct IndexNavigationCoverage: Sendable {
    struct Fact: Sendable { let order: UInt64; let covered: Bool }
    struct Region: Sendable {
        let root: SourceRoot
        let context: SourceRootPathContext
        var facts: [RootRelativeScope: Fact]
    }
    private struct IndexedRegion: Sendable {
        let root: SourceRoot
        let context: SourceRootPathContext
        var index: NavigationScopeIndex
    }
    public let contentGeneration: IndexContentGeneration
    public let scope: IndexScope
    let performedFullScan: Bool
    private var order: UInt64 = 0
    // Only a freshly-produced value retains its delta. A merged cache holds the
    // persistent index, with no accumulated full-file dictionary to filter.
    private var delta: [String: IndexedRegion]
    private var regions: [String: IndexedRegion] = [:]
    init(contentGeneration: IndexContentGeneration, scope: IndexScope, regions: [Region], performedFullScan: Bool = false) {
        self.contentGeneration = contentGeneration; self.scope = scope; self.performedFullScan = performedFullScan; delta = [:]
        for region in regions {
            self.regions[region.root.id] = .init(root: region.root, context: region.context,
                index: Self.applying(region.facts, to: .init(), order: 0))
        }
        delta = self.regions
    }
    private static func key(_ relative: RootRelativeScope) -> [UInt8] {
        Array((relative.isRoot ? "" : relative.comparisonKey + "/").utf8)
    }
    private static func applying(_ facts: [RootRelativeScope: Fact], to original: NavigationScopeIndex,
                                 order: UInt64) -> NavigationScopeIndex {
        var index = original
        for (path, fact) in facts.sorted(by: { $0.key.components.count < $1.key.components.count }) {
            index = index.setting(key(path), .init(rank: .init(admission: order), covered: fact.covered))
        }
        return index
    }
    public func covers(_ reference: SessionNavigationReference) -> Bool {
        guard let region = regions[reference.agent + ":" + reference.root],
              let relative = region.root.relativeScope(forStoredPath: reference.path, in: region.context) else { return false }
        return region.index.latest(Self.key(relative))?.covered == true
    }
    fileprivate func absoluteKey(_ reference: SessionNavigationReference) -> [UInt8]? {
        guard let region = regions[reference.agent + ":" + reference.root],
              let relative = region.root.relativeScope(forStoredPath: reference.path, in: region.context) else { return nil }
        let base = region.context.scanPath.path
        let absolute = relative.isRoot ? base : (base == "/" ? "/" : base + "/") + relative.path
        return navigationAbsoluteKey(TraceFileIO.comparisonKey(absolute, caseSensitive: relative.isCaseSensitive))
    }
    public func merging(_ newer: Self) -> Self {
        guard contentGeneration == newer.contentGeneration, scope == newer.scope else { return newer }
        var result = self; result.order &+= 1; result.delta = [:]
        for (id, region) in newer.delta {
            let old = result.regions[id]
            var index = old?.context == region.context ? old!.index : .init()
            region.index.visit { key, fact in
                index = index.setting(key, .init(rank: .init(admission: result.order), covered: fact.covered))
            }
            result.regions[id] = .init(root: region.root, context: region.context, index: index)
        }
        // Public callers may combine previously merged values too. Traverse only
        // that supplied value when it has no producer delta.
        if newer.delta.isEmpty {
            let offset = result.order
            for (id, incoming) in newer.regions {
                var index = result.regions[id].flatMap { $0.context == incoming.context ? $0.index : nil } ?? .init()
                var facts: [([UInt8], NavigationFact)] = []
                incoming.index.visit { facts.append(($0, $1)) }
                for (key, fact) in facts.sorted(by: { $0.1.rank < $1.1.rank }) {
                    index = index.setting(key, .init(rank: .init(admission: offset + fact.rank.admission), covered: fact.covered))
                }
                result.regions[id] = .init(root: incoming.root, context: incoming.context, index: index)
            }
            result.order += newer.order
        }
        return result
    }
    fileprivate var rootKeys: [[UInt8]] {
        regions.values.map { navigationAbsoluteKey($0.context.scanPath.comparisonKey) }
    }
    fileprivate func observationIndex(admission: UInt64, execution: UInt64) -> NavigationScopeIndex {
        var result = NavigationScopeIndex()
        for region in delta.values {
            let base = navigationAbsoluteKey(region.context.scanPath.comparisonKey)
            region.index.visit { key, fact in
                result = result.setting(base + key, .init(rank: .init(admission: admission, execution: execution), covered: fact.covered))
            }
        }
        return result
    }
}

/// Prepared without filesystem access when canonical identities already exist.
/// Preparation creates no obligation; reserve makes it synchronously visible.
public struct IndexNavigationInputs: Sendable {
    fileprivate let index: NavigationScopeIndex
    fileprivate let fullScan: Bool
    public init(canonicalPaths: Set<TraceFileIO.CanonicalPath>,
                canonicalReconciliationPaths: Set<TraceFileIO.CanonicalPath>, fullScan: Bool = false) {
        var index = NavigationScopeIndex()
        let fact = NavigationFact(rank: .init(admission: 0), covered: false)
        if fullScan { index = index.setting([], fact) }
        for path in canonicalPaths.union(canonicalReconciliationPaths) {
            index = index.setting(navigationAbsoluteKey(path.comparisonKey), fact)
        }
        self.index = index; self.fullScan = fullScan
    }
    fileprivate init(index: NavigationScopeIndex, fullScan: Bool) { self.index = index; self.fullScan = fullScan }
}

/// An immutable sequence treap makes admission and removal logarithmic without
/// copying a corpus-sized dictionary while readers hold a snapshot.
private final class NavigationAdmissions: Sendable {
    let sequence: UInt64, priority: UInt64
    let inputs: IndexNavigationInputs
    let left: NavigationAdmissions?, right: NavigationAdmissions?
    init(_ sequence: UInt64, _ inputs: IndexNavigationInputs, _ left: NavigationAdmissions? = nil, _ right: NavigationAdmissions? = nil) {
        self.sequence = sequence; self.inputs = inputs; self.left = left; self.right = right
        var hash = sequence &+ 0x9e3779b97f4a7c15
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        priority = hash ^ (hash >> 31)
    }
    static func merge(_ a: NavigationAdmissions?, _ b: NavigationAdmissions?) -> NavigationAdmissions? {
        guard let a else { return b }; guard let b else { return a }
        if a.priority > b.priority { return .init(a.sequence, a.inputs, a.left, merge(a.right, b)) }
        return .init(b.sequence, b.inputs, merge(a, b.left), b.right)
    }
    func split(after sequence: UInt64) -> (NavigationAdmissions?, NavigationAdmissions?) {
        if self.sequence <= sequence {
            let parts = right?.split(after: sequence) ?? (nil, nil)
            return (.init(self.sequence, inputs, left, parts.0), parts.1)
        }
        let parts = left?.split(after: sequence) ?? (nil, nil)
        return (parts.0, .init(self.sequence, inputs, parts.1, right))
    }
    func removing(_ sequence: UInt64) -> NavigationAdmissions? {
        if self.sequence == sequence { return Self.merge(left, right) }
        if sequence < self.sequence { return .init(self.sequence, inputs, left?.removing(sequence), right) }
        return .init(self.sequence, inputs, left, right?.removing(sequence))
    }
    func visit(_ body: (UInt64, IndexNavigationInputs) -> Void) { left?.visit(body); body(sequence, inputs); right?.visit(body) }
    func required(_ key: [UInt8]) -> UInt64? {
        if let newest = right?.required(key) { return newest }
        if inputs.index.latest(key) != nil { return sequence }
        return left?.required(key)
    }
}

/// Database-owned source obligations. Admission never takes the folding lock.
public final class IndexNavigationWorkLedger: Sendable {
    private struct State {
        var sequence: UInt64 = 0, execution: UInt64 = 0, revision: UInt64 = 0
        var pending: NavigationAdmissions?
        var observed = NavigationScopeIndex()
        var content: IndexContentGeneration?
        var scope: IndexScope?
        var contextExecution: UInt64 = 0
        var executions: Set<UInt64> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // Only background coverage builders take this lock. Main-actor admission,
    // absence queries and retirement take short state snapshots instead.
    private let folding = NSLock()
    #if DEBUG
    private let observationHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    func setObservationHookForTesting(_ hook: (@Sendable () -> Void)?) { observationHook.withLock { $0 = hook } }
    #endif
    public init() {}
    public func reserve(canonicalPaths: Set<TraceFileIO.CanonicalPath>,
                        canonicalReconciliationPaths: Set<TraceFileIO.CanonicalPath>, fullScan: Bool = false) -> [IndexNavigationWork] {
        reserve(.init(canonicalPaths: canonicalPaths, canonicalReconciliationPaths: canonicalReconciliationPaths, fullScan: fullScan))
    }
    public func reserve(_ inputs: IndexNavigationInputs) -> [IndexNavigationWork] {
        guard inputs.index.maximum != nil else { return [] }
        return state.withLock { value in
            value.sequence &+= 1
            value.pending = NavigationAdmissions.merge(value.pending, .init(value.sequence, inputs))
            return [.init(ledger: self, sequence: value.sequence)]
        }
    }
    public func permitsAbsence(_ reference: SessionNavigationReference, coverage: IndexNavigationCoverage) -> Bool {
        guard coverage.covers(reference), let key = coverage.absoluteKey(reference) else { return false }
        let snapshot = state.withLock { ($0.pending, $0.observed, $0.content, $0.scope) }
        guard let needed = snapshot.0?.required(key) else { return true }
        guard snapshot.2 == coverage.contentGeneration, snapshot.3 == coverage.scope,
              let paid = snapshot.1.latest(key), paid.covered else { return false }
        return paid.rank.admission >= needed
    }
    fileprivate func retire(_ sequence: UInt64) {
        let retired = state.withLock { value -> NavigationAdmissions? in
            let previous = value.pending
            value.pending = previous?.removing(sequence); value.revision &+= 1
            return previous
        }
        withExtendedLifetime(retired) {} // Large prepared deltas are released outside the ingress lock.
    }
    fileprivate func begin() -> UInt64 {
        state.withLock { value in value.execution &+= 1; value.executions.insert(value.execution); return value.execution }
    }
    fileprivate func finish(_ execution: UInt64) {
        state.withLock { $0.executions.remove(execution) }
        folding.lock(); defer { folding.unlock() }
        let snapshot = state.withLock { $0 }
        guard snapshot.executions.isEmpty else { return }
        let compact = Self.compact(snapshot.observed, pending: snapshot.pending)
        state.withLock { value in
            if value.revision == snapshot.revision { value.observed = compact; value.revision &+= 1 }
        }
    }
    private static func compact(_ observed: NavigationScopeIndex, pending: NavigationAdmissions?) -> NavigationScopeIndex {
        var needed = NavigationScopeIndex()
        pending?.visit { admission, inputs in
            inputs.index.visit { key, _ in needed = needed.setting(key, .init(rank: .init(admission: admission), covered: false)) }
        }
        var compact = NavigationScopeIndex()
        observed.visit { key, fact in
            guard let requirement = needed.maximumIntersecting(key) else { return }
            if fact.covered, let parent = compact.latest(key), parent.covered,
               parent.rank.admission >= requirement.admission { return }
            compact = compact.setting(key, fact)
        }
        return compact
    }
    fileprivate func observe(_ coverage: IndexNavigationCoverage, through sequence: UInt64, execution: UInt64) {
        folding.lock(); defer { folding.unlock() }
        let observations = coverage.observationIndex(admission: sequence, execution: execution)
        while true {
            let snapshot = state.withLock { $0 }
            let sameContext = snapshot.content == coverage.contentGeneration && snapshot.scope == coverage.scope
            guard sameContext || execution >= snapshot.contextExecution else { return }
            var observed = sameContext ? snapshot.observed : .init()
            observations.visit { key, fact in observed = observed.setting(key, fact) }
            var remaining: NavigationAdmissions?
            let captured = snapshot.sequence
            snapshot.pending?.visit { admission, inputs in
                var required = NavigationScopeIndex()
                if inputs.fullScan, coverage.performedFullScan, admission <= sequence {
                    for key in coverage.rootKeys where !observed.fullyCovered(key, through: admission) {
                        required = required.setting(key, .init(rank: .init(admission: admission), covered: false))
                    }
                } else {
                    inputs.index.visit { key, _ in
                        if !observed.fullyCovered(key, through: admission) {
                            required = required.setting(key, .init(rank: .init(admission: admission), covered: false))
                        }
                    }
                }
                if required.maximum != nil {
                    let expanded = inputs.fullScan && coverage.performedFullScan && admission <= sequence
                    remaining = NavigationAdmissions.merge(remaining, .init(admission, .init(index: required, fullScan: inputs.fullScan && !expanded)))
                }
            }
            // A paid leaf needs no retained history after older executions have
            // retired. Keep failure exceptions and facts needed by broad debt.
            if snapshot.executions.allSatisfy({ $0 >= execution }) {
                observed = Self.compact(observed, pending: remaining)
            }
            let folded = remaining, accepted = observed
            #if DEBUG
            observationHook.withLock { $0 }?()
            #endif
            let committed = state.withLock { value -> Bool in
                guard value.revision == snapshot.revision else { return false }
                let later = value.pending?.split(after: captured).1
                value.pending = NavigationAdmissions.merge(folded, later)
                value.observed = accepted; value.content = coverage.contentGeneration; value.scope = coverage.scope
                value.contextExecution = max(value.contextExecution, execution); value.revision &+= 1
                return true
            }
            if committed { return }
        }
    }
    #if DEBUG
    public var countsForTesting: [String: Int] { retainedCounts }
    #endif
    #if TRACE_CHECKPOINT_BENCHMARK
    public var benchmarkCounts: [String: Int] { retainedCounts }
    #endif
    private var retainedCounts: [String: Int] {
        let snapshot = state.withLock { ($0.pending, $0.observed, $0.executions.count) }
        var required = 0, nodes = 0, receipts = 0
        snapshot.0?.visit { _, inputs in let count = inputs.index.counts; required += count.facts; nodes += count.nodes; receipts += 1 }
        let observed = snapshot.1.counts
        return ["requiredScopeFacts": required, "observedScopeFacts": observed.facts,
                "scopeNodes": nodes + observed.nodes, "pendingReceipts": receipts, "activeExecutions": snapshot.2]
    }
}
/// Opaque enrollment shared by every fragment of its original delivery.
public struct IndexNavigationWork: Sendable {
    fileprivate let ledger: IndexNavigationWorkLedger
    fileprivate let sequence: UInt64
    /// Only an owner abandoning work before delivery may retire its enrollment.
    public func retire() { ledger.retire(sequence) }
    public static func coalesced(_ inputs: [Self]) -> [Self] {
        var latest: [ObjectIdentifier: Self] = [:]
        for input in inputs {
            let key = ObjectIdentifier(input.ledger)
            if latest[key].map({ $0.sequence < input.sequence }) ?? true { latest[key] = input }
        }
        return Array(latest.values)
    }
    struct Execution: Sendable { let work: IndexNavigationWork; let sequence: UInt64 }
    static func begin(_ inputs: [Self]) -> [Execution] {
        coalesced(inputs).map { .init(work: $0, sequence: $0.ledger.begin()) }
    }
    static func observe(_ coverage: IndexNavigationCoverage, executions: [Execution]) {
        for execution in executions { execution.work.ledger.observe(coverage, through: execution.work.sequence, execution: execution.sequence) }
    }
    static func finish(_ executions: [Execution]) {
        for execution in executions { execution.work.ledger.finish(execution.sequence) }
    }
}

/// An opaque source identity used to restore navigation after row IDs change.
/// It is captured by IndexDatabase, never constructed from presentation text.
public struct SessionNavigationReference: Hashable, Codable, Sendable {
    let agent: String
    let root: String
    let path: String
    let externalSessionID: String
    let anchorSourceKey: String?
    let anchorExternalID: String?

    public func representsSameSession(as other: Self) -> Bool {
        agent == other.agent && root == other.root && path == other.path && externalSessionID == other.externalSessionID
    }
    public func anchored(at identity: MessageNavigationIdentity) -> Self {
        .init(agent: agent, root: root, path: path, externalSessionID: externalSessionID,
            anchorSourceKey: identity.sourceKey, anchorExternalID: identity.externalID)
    }

    public func preservingAnchor(from reference: Self) -> Self {
        let anchored = anchorSourceKey != nil || anchorExternalID != nil
        return .init(agent: agent, root: root, path: path, externalSessionID: externalSessionID,
            anchorSourceKey: anchored ? anchorSourceKey : reference.anchorSourceKey,
            anchorExternalID: anchored ? anchorExternalID : reference.anchorExternalID)
    }

    /// Match with the same precedence as database resolution: an external ID
    /// owns the anchor even if a rewrite changed its source offset.
    public func matchesAnchor(_ identity: MessageNavigationIdentity) -> Bool {
        if let external = anchorExternalID { return identity.externalID == external }
        if let key = anchorSourceKey { return identity.sourceKey == key }
        return false
    }

    public var hasStableAnchor: Bool { anchorSourceKey != nil || anchorExternalID != nil }

    public var unanchored: Self {
        .init(agent: agent, root: root, path: path, externalSessionID: externalSessionID,
            anchorSourceKey: nil, anchorExternalID: nil)
    }


}

public struct MessageNavigationIdentity: Hashable, Sendable {
    let sourceKey: String
    let externalID: String?
}

public struct SessionSummary: Identifiable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let projectCanonicalKey: String
    public let agent: AgentKind
    public let title: String
    public var hasPlan: Bool = false
    public let startedAtMilliseconds: Int64
    public let lastActivityMilliseconds: Int64
    public let messageCount: Int
    public let hadError: Bool
    public let sourcePath: String
    public var sourceGeneration: Int64 = 0
    public var errorRevision: Int64 = 0
    public var contentGeneration: IndexContentGeneration? = nil
    public var navigationReference: SessionNavigationReference? = nil

    public var transcriptIdentity: SessionTranscriptIdentity { .init(self) }
}

/// Identifies the source contents backing a transcript, independently of its
/// growing row count and display metadata.
public struct SessionTranscriptIdentity: Equatable, Sendable {
    public let contentGeneration: IndexContentGeneration?
    public let sessionID: Int64
    public let sourceGeneration: Int64
    public let sourcePath: String

    public init(_ session: SessionSummary) {
        contentGeneration = session.contentGeneration
        sessionID = session.id
        sourceGeneration = session.sourceGeneration
        sourcePath = session.sourcePath
    }
}

/// Metadata and rows read from one database snapshot. Nil rows mean that the
/// caller's known generation, source path, and row count are still current.
public struct SessionTranscriptSnapshot: Sendable {
    /// Increasing read order within the IndexDatabase instance that produced this snapshot.
    public let readRevision: UInt64
    public let session: SessionSummary?
    public let messages: [MessageSummary]?
    public var contentGeneration: IndexContentGeneration? = nil
}

public struct MessageSummary: Identifiable, Sendable {
    public let id: Int64
    public let role: MessageRole
    public let timestampMilliseconds: Int64
    public let prefix: String
    public let toolSummary: String?
    public let characterCount: Int
    public let hasError: Bool
    public let sourcePath: String
    public let sourceFormat: SourceFormat
    public let locator: RecordLocator
    public var sectionFlags: Int? = nil
    public var navigationIdentity: MessageNavigationIdentity? = nil
}

public struct SourceHealth: Identifiable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let rootPath: String
    public let fileCount: Int
    public let earliestSessionMilliseconds: Int64?
    public let lastScanMilliseconds: Int64?
    public let error: String?
}

public struct UsageRollup: Identifiable, Sendable {
    public var id: String { "\(day):\(projectID):\(model):\(isSidechain)" }
    public let day: String
    public let projectID: Int64
    public let projectName: String
    public let model: String
    public let isSidechain: Bool
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheWriteTokens: Int64
    public let cacheReadTokens: Int64
    public let reasoningTokens: Int64

    public init(
        day: String,
        projectID: Int64,
        projectName: String,
        model: String,
        isSidechain: Bool,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64,
        cacheReadTokens: Int64,
        reasoningTokens: Int64
    ) {
        self.day = day
        self.projectID = projectID
        self.projectName = projectName
        self.model = model
        self.isSidechain = isSidechain
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
    }
}

public struct IndexStatistics: Sendable {
    public let sourceFileCount: Int
    public let projectCount: Int
    public let sessionCount: Int
    public let messageCount: Int
    public let databaseBytes: Int64
}

public enum CostRange: String, CaseIterable, Sendable, Identifiable {
    case sevenDays
    case thirtyDays
    case yearToDate
    case allTime
    case custom

    public var id: String { rawValue }
}

public struct SessionFailure: Sendable, Identifiable {
    public var id: String { "\(timestampMilliseconds):\(kind):\(detail)" }
    public let timestampMilliseconds: Int64
    public let kind: String
    public let toolName: String?
    public let detail: String
    public let locator: RecordLocator?
}

public struct TranscriptVisibility: Hashable, Sendable {
    public var tools: Bool
    public var system: Bool
    public var reasoning: Bool

    public init(tools: Bool = true, system: Bool = true, reasoning: Bool = true) {
        self.tools = tools
        self.system = system
        self.reasoning = reasoning
    }

    public func includes(role: MessageRole) -> Bool {
        switch role {
        case .system: system
        case .reasoning: reasoning
        case .toolUse, .toolResult: tools
        default: true
        }
    }

    public func includes(_ message: MessageSummary) -> Bool {
        if message.hasError { return true }
        // System is a record category; section switches also apply inside it.
        if !includes(role: message.role) { return false }
        if let flags = message.sectionFlags {
            if flags == 0 { return false }
            let includesAttachment = flags & 8 != 0 && includes(role: message.role)
            return flags & 1 != 0 || (tools && flags & 2 != 0) || (reasoning && flags & 4 != 0) || includesAttachment
        }
        return includes(role: message.role)
    }

    public func text(_ message: HydratedMessage, expandedReasoning: Bool) -> String {
        guard message.role != .system || system else { return "" }
        var sections = [message.sections.prose]
        if tools { sections += [message.sections.toolInvocation, message.sections.toolOutput] }
        if reasoning && expandedReasoning { sections.append(message.sections.reasoning) }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

#if TRACE_CHECKPOINT_BENCHMARK
extension IndexNavigationCoverage {
    public static func benchmarkFixture(generation: IndexContentGeneration, names: [String], covered: Bool) -> Self {
        let root = SourceRoot(agent: .claudeCode, url: URL(fileURLWithPath: "/tmp/navigation-cache"))
        let context = root.mappingContext
        let facts = Dictionary(uniqueKeysWithValues: names.map {
            (RootRelativeScope(components: $0.isEmpty ? [] : [$0], caseSensitive: context.scanPath.isCaseSensitive), Fact(order: 0, covered: covered))
        })
        return .init(contentGeneration: generation, scope: .proseOnly, regions: [Region(root: root, context: context, facts: facts)])
    }
    public func benchmarkCovers(_ name: String) -> Bool {
        guard let region = regions.values.first else { return false }
        return covers(.init(agent: region.root.agent.rawValue, root: region.root.url.path,
            path: region.context.scanPath.path + "/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil))
    }
}
#endif

#if TRACE_CHECKPOINT_BENCHMARK
// TRACE_NAVIGATION_LEDGER_WORKLOAD_V2
extension IndexNavigationWorkLedger {
    public func benchmarkAdmission(_ paths: Set<TraceFileIO.CanonicalPath>) -> @Sendable () -> [IndexNavigationWork] {
        let inputs = IndexNavigationInputs(canonicalPaths: paths, canonicalReconciliationPaths: [])
        return { self.reserve(inputs) }
    }
    public func benchmarkObserve(_ coverage: IndexNavigationCoverage, work: [IndexNavigationWork]) {
        let executions = IndexNavigationWork.begin(work)
        let stamp = CheckpointAcceptanceBenchmark.begin()
        IndexNavigationWork.observe(coverage, executions: executions)
        IndexNavigationWork.finish(executions)
        CheckpointAcceptanceBenchmark.end(stamp)
    }
}
extension IndexNavigationCoverage {
    public func benchmarkReference(_ name: String) -> SessionNavigationReference {
        let region = regions.values.first!
        return .init(agent: region.root.agent.rawValue, root: region.root.url.path,
            path: region.context.scanPath.path + "/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil)
    }
}
#endif
