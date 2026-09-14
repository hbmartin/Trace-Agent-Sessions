import Foundation
import os

public struct IndexProgress: Sendable {
    public enum Phase: String, Sendable {
        case discovering
        case indexing
        case reconciling
        case aggregating
        case complete
        case failed
    }

    public let phase: Phase
    public let agent: AgentKind?
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentPath: String?
    public let error: String?

    public init(
        phase: Phase,
        agent: AgentKind? = nil,
        completedFiles: Int = 0,
        totalFiles: Int = 0,
        currentPath: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.agent = agent
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentPath = currentPath
        self.error = error
    }
}

public actor IndexCoordinator {
    private let database: IndexDatabase
    private let sources: [any SessionSource]
    private let logger = Logger(subsystem: "me.haroldmartin.Trace", category: "index")

    public init(database: IndexDatabase, sources: [any SessionSource]) {
        self.database = database
        self.sources = sources
    }

    public func indexAll(
        scope: IndexScope,
        progress: @escaping @Sendable (IndexProgress) -> Void = { _ in }
    ) async {
        do {
            try await database.setIndexScope(scope)
            progress(.init(phase: .discovering))
            var discoveredByAgent: [AgentKind: [DiscoveredSourceFile]] = [:]
            var rootIDs: [String: Int64] = [:]
            var rootErrors: [String: String] = [:]

            for source in sources {
                for root in source.roots {
                    rootIDs[root.id] = try await database.register(root: root)
                }
                let files = try source.discover()
                discoveredByAgent[source.agent] = files
            }

            let allFiles = AgentKind.allCases.flatMap { discoveredByAgent[$0] ?? [] }
            for (index, file) in allFiles.enumerated() {
                progress(.init(
                    phase: .indexing,
                    agent: file.agent,
                    completedFiles: index,
                    totalFiles: allFiles.count,
                    currentPath: file.url.path
                ))
                guard let source = source(for: file.agent),
                      let rootID = rootIDs["\(file.agent.rawValue):\(file.root.standardizedFileURL.path)"]
                else { continue }
                do {
                    try await process(file: file, using: source, rootID: rootID, scope: scope)
                } catch {
                    logger.error("Index failed for \(file.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    try? await database.recordSourceError(path: file.url.path, error: error.localizedDescription)
                    rootErrors["\(file.agent.rawValue):\(file.root.standardizedFileURL.path)"] = error.localizedDescription
                }
            }

            progress(.init(phase: .reconciling, completedFiles: allFiles.count, totalFiles: allFiles.count))
            for agent in AgentKind.allCases {
                let livePaths = Set((discoveredByAgent[agent] ?? []).map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
                for stored in try await database.paths(agent: agent) where !livePaths.contains(stored.path) {
                    try await database.deleteSource(id: stored.id)
                }
            }

            for source in sources {
                for root in source.roots {
                    if let rootID = rootIDs[root.id] {
                        try await database.recordRootScan(rootID: rootID, error: rootErrors[root.id])
                    }
                }
            }

            progress(.init(phase: .aggregating, completedFiles: allFiles.count, totalFiles: allFiles.count))
            try await database.rebuildUsageRollups()
            progress(.init(phase: .complete, completedFiles: allFiles.count, totalFiles: allFiles.count))
        } catch {
            logger.error("Index run failed: \(error.localizedDescription, privacy: .public)")
            progress(.init(phase: .failed, error: error.localizedDescription))
        }
    }

    public func refresh(
        paths: Set<String>,
        scope: IndexScope,
        progress: @escaping @Sendable (IndexProgress) -> Void = { _ in }
    ) async {
        var needsFullReconcile = false
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? await database.deleteSource(path: url.path)
                continue
            }
            guard let (source, file, root) = classify(url: url) else {
                if url.hasDirectoryPath { needsFullReconcile = true }
                continue
            }
            do {
                let rootID = try await database.register(root: root)
                try await process(file: file, using: source, rootID: rootID, scope: scope)
            } catch {
                logger.error("Refresh failed for \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                try? await database.recordSourceError(path: url.path, error: error.localizedDescription)
            }
        }
        if needsFullReconcile {
            await indexAll(scope: scope, progress: progress)
        } else {
            try? await database.rebuildUsageRollups()
        }
    }

    public func hydrate(_ summary: MessageSummary) async throws -> HydratedMessage {
        guard let source = source(for: agent(for: summary.sourceFormat)) else {
            throw SessionSourceError.unsupportedLocator
        }
        return try source.hydrate(
            fileURL: URL(fileURLWithPath: summary.sourcePath),
            format: summary.sourceFormat,
            locator: summary.locator
        )
    }

    public func hydrate(messageID: Int64) async throws -> HydratedMessage {
        guard let summary = try await database.message(id: messageID) else {
            throw SessionSourceError.missingRecord(String(messageID))
        }
        return try await hydrate(summary)
    }

    private func process(
        file: DiscoveredSourceFile,
        using source: any SessionSource,
        rootID: Int64,
        scope: IndexScope,
        attempt: Int = 0
    ) async throws {
        let initialFingerprint = try TraceFileIO.fingerprint(url: file.url)
        var state = try await database.sourceState(path: file.url.path)

        if state == nil,
           let moved = try await database.sourceState(device: initialFingerprint.device, inode: initialFingerprint.inode) {
            try await database.moveSource(id: moved.id, rootID: rootID, path: file.url.path)
            state = try await database.sourceState(path: file.url.path)
        }

        if let state,
           state.size == initialFingerprint.size,
           state.modificationNanoseconds == initialFingerprint.modificationNanoseconds,
           state.scannedBytes == state.size,
           state.headLength == initialFingerprint.headLength,
           state.headHash == initialFingerprint.headHash {
            return
        }

        if file.format == .geminiJSON {
            let sourceID = if let state {
                state.id
            } else {
                try await database.createSource(rootID: rootID, file: file, fingerprint: initialFingerprint)
            }
            try await processSnapshot(
                file: file,
                using: source,
                rootID: rootID,
                sourceID: sourceID,
                initialFingerprint: initialFingerprint,
                scope: scope,
                attempt: attempt
            )
            return
        }

        let sourceID: Int64
        let startOffset: Int64
        if let state {
            let comparison = try TraceFileIO.fingerprint(url: file.url, preferredHeadLength: state.headLength)
            let appendable = comparison.inode == state.inode
                && comparison.device == state.device
                && comparison.size >= state.scannedBytes
                && comparison.headHash == state.headHash
            sourceID = state.id
            if appendable {
                startOffset = state.scannedBytes
            } else {
                try await database.replaceSourceContents(id: state.id)
                startOffset = 0
            }
        } else {
            sourceID = try await database.createSource(rootID: rootID, file: file, fingerprint: initialFingerprint)
            startOffset = 0
        }

        var batch: [ParsedRecord] = []
        var checkpoint = startOffset
        for try await record in source.records(in: file, from: startOffset) {
            if case .checkpoint(let offset) = record { checkpoint = offset }
            batch.append(record)
            if batch.count >= 250 {
                try await database.insert(records: batch, sourceFileID: sourceID, scope: scope)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await database.insert(records: batch, sourceFileID: sourceID, scope: scope)
        }

        let finalFingerprint = try TraceFileIO.fingerprint(
            url: file.url,
            preferredHeadLength: initialFingerprint.headLength == 0 ? nil : initialFingerprint.headLength
        )
        let wasReplaced = finalFingerprint.device != initialFingerprint.device
            || finalFingerprint.inode != initialFingerprint.inode
            || (initialFingerprint.headLength > 0 && finalFingerprint.headHash != initialFingerprint.headHash)
            || (finalFingerprint.size == initialFingerprint.size
                && finalFingerprint.modificationNanoseconds != initialFingerprint.modificationNanoseconds)
        if finalFingerprint.size < checkpoint || wasReplaced {
            try await database.replaceSourceContents(id: sourceID)
            guard attempt < 2 else {
                throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
            }
            try await process(file: file, using: source, rootID: rootID, scope: scope, attempt: attempt + 1)
            return
        }
        try await database.finishSource(id: sourceID, fingerprint: finalFingerprint, scannedBytes: checkpoint)
        if finalFingerprint != initialFingerprint,
           finalFingerprint.size > checkpoint,
           attempt < 2 {
            try await process(file: file, using: source, rootID: rootID, scope: scope, attempt: attempt + 1)
        }
    }

    private func processSnapshot(
        file: DiscoveredSourceFile,
        using source: any SessionSource,
        rootID: Int64,
        sourceID: Int64,
        initialFingerprint: SourceFingerprint,
        scope: IndexScope,
        attempt: Int
    ) async throws {
        var records: [ParsedRecord] = []
        var checkpoint: Int64 = 0
        for try await record in source.records(in: file, from: 0) {
            if case .checkpoint(let offset) = record { checkpoint = offset }
            records.append(record)
        }

        let finalFingerprint = try TraceFileIO.fingerprint(
            url: file.url,
            preferredHeadLength: initialFingerprint.headLength == 0 ? nil : initialFingerprint.headLength
        )
        guard finalFingerprint == initialFingerprint else {
            guard attempt < 2 else {
                throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
            }
            try await process(file: file, using: source, rootID: rootID, scope: scope, attempt: attempt + 1)
            return
        }

        try await database.replaceSnapshotContents(
            id: sourceID,
            records: records,
            scope: scope,
            fingerprint: finalFingerprint,
            scannedBytes: checkpoint
        )
    }

    private func source(for agent: AgentKind) -> (any SessionSource)? {
        sources.first { $0.agent == agent }
    }

    private func agent(for format: SourceFormat) -> AgentKind {
        switch format {
        case .claudeJSONL: .claudeCode
        case .codexJSONL: .codex
        case .geminiJSON, .geminiJSONL: .gemini
        }
    }

    private func classify(url: URL) -> (any SessionSource, DiscoveredSourceFile, SourceRoot)? {
        for source in sources {
            for root in source.roots where url.path.hasPrefix(root.url.path + "/") {
                let format: SourceFormat?
                switch source.agent {
                case .claudeCode:
                    format = url.pathExtension == "jsonl" ? .claudeJSONL : nil
                case .codex:
                    format = url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") ? .codexJSONL : nil
                case .gemini:
                    guard url.deletingLastPathComponent().lastPathComponent == "chats",
                          url.lastPathComponent.hasPrefix("session-") else { continue }
                    format = url.pathExtension == "jsonl" ? .geminiJSONL : (url.pathExtension == "json" ? .geminiJSON : nil)
                }
                if let format {
                    return (source, .init(agent: source.agent, root: root.url, url: url, format: format), root)
                }
            }
        }
        return nil
    }
}
