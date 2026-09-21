import Foundation

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
    let hasSymlinkedComponent: Bool

    public init(agent: AgentKind, url: URL, isDefault: Bool = true) {
        self.agent = agent
        // The configured path is the durable identity. Resolving it here made the
        // same symlink alternate identities as its target mounted and unmounted.
        self.url = url.standardized
        self.isDefault = isDefault
        let resolved = Self.resolveScanURL(self.url)
        cachedScanURL = resolved.url
        cachedScanPath = TraceFileIO.canonicalPath(resolved.url.path)
        hasSymlinkedComponent = resolved.encounteredSymlink
    }

    /// The stable path used for I/O during this source configuration. Every
    /// symlinked component is resolved lexically, including dangling targets.
    public var scanURL: URL { cachedScanURL }
    var scanPath: TraceFileIO.CanonicalPath { cachedScanPath }

    /// Resolves a discovery scope against this root's scan identity. The fallback
    /// through the configured path also handles a dangling symlink, which
    /// `URL.resolvingSymlinksInPath()` cannot resolve on its own.
    func canonicalScopePath(_ rawPath: String) -> TraceFileIO.CanonicalPath {
        let direct = TraceFileIO.canonicalPath(rawPath)
        if cachedScanPath.contains(direct) { return direct }

        let configured = TraceFileIO.canonicalPath(url.path)
        guard configured.contains(direct) else { return direct }
        let suffix = directURLComponents(direct.path).dropFirst(
            directURLComponents(configured.path).count
        )
        var mapped = cachedScanURL
        for component in suffix { mapped.appendPathComponent(component) }
        return TraceFileIO.canonicalPath(mapped.path)
    }

    /// Converts a canonical scan scope back to the configured root spelling so
    /// its durable identity survives a later symlink repoint.
    func configuredScopePath(_ scope: TraceFileIO.CanonicalPath) -> String {
        guard cachedScanPath.contains(scope) else { return scope.path }
        let suffix = directURLComponents(scope.path).dropFirst(
            directURLComponents(cachedScanPath.path).count
        )
        var configured = url
        for component in suffix { configured.appendPathComponent(component) }
        return configured.standardized.path
    }

    private func directURLComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardized.pathComponents
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

public enum ParsedRecord: Sendable {
    case message(ParsedMessage)
    case usage(ParsedUsageRecord)
    case event(ParsedSessionEvent)
    case sessionContext(String)
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
}

public struct SearchPage: Sendable {
    public let results: [SearchResult]
    public let nextCursor: SearchCursor?

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
