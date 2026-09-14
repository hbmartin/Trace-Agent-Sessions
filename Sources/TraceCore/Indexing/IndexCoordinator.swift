import Foundation
import os

public struct IndexProgress: Sendable {
    public enum Phase: String, Sendable {
        case waiting, discovering, indexing, reconciling, aggregating, complete, cancelled, failed
    }
    public var phase: Phase
    public var runID: UUID
    public var sequence: Int = 0
    public var incremental: Bool = false
    public var agent: AgentKind?
    public var completedFiles: Int
    public var totalFiles: Int
    public var indexedFiles: Int = 0
    public var unchangedFiles: Int = 0
    public var failedFiles: Int = 0
    public var committedBytes: Int64 = 0
    public var currentFileBytes: Int64 = 0
    public var currentFileTotalBytes: Int64 = 0
    public var projectName: String?
    public var currentPath: String?
    public var error: String?

    public init(phase: Phase, agent: AgentKind? = nil, completedFiles: Int = 0,
                totalFiles: Int = 0, currentPath: String? = nil, error: String? = nil,
                runID: UUID = UUID()) {
        self.phase = phase
        self.agent = agent
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentPath = currentPath
        self.error = error
        self.runID = runID
    }
}

/// Actors are reentrant at database awaits: an explicit permit protects an entire pass.
private actor IndexRunGate {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { held = false }
        else { waiting.removeFirst().resume() }
    }
}

public actor IndexCoordinator {
    private let database: IndexDatabase
    private let sources: [any SessionSource]
    private let gate = IndexRunGate()
    private let logger = Logger(subsystem: "me.haroldmartin.Trace", category: "index")

    public init(database: IndexDatabase, sources: [any SessionSource]) {
        self.database = database
        self.sources = sources
    }

    public func indexAll(scope: IndexScope, rebuild: Bool = false,
                         progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async {
        await gate.acquire()
        await run(scope: scope, paths: nil, rebuild: rebuild, progress: progress)
        await gate.release()
    }

    public func refresh(paths: Set<String>, scope: IndexScope,
                        progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async {
        await gate.acquire()
        await run(scope: scope, paths: paths, rebuild: false, progress: progress)
        await gate.release()
    }

    private func run(scope: IndexScope, paths: Set<String>?, rebuild: Bool,
                     progress: @escaping @Sendable (IndexProgress) async -> Void) async {
        var status = IndexProgress(phase: .discovering)
        status.incremental = paths != nil
        do {
            try Task.checkCancellation()
            let oldScope = try await database.storedIndexScope()
            if rebuild || oldScope != scope { try await database.clearIndex() }
            try await database.setIndexScope(scope)
            await progress(status)
            var rootIDs: [String: Int64] = [:]
            for source in sources {
                for root in source.roots { rootIDs[root.id] = try await database.register(root: root) }
            }
            var allFiles: [DiscoveredSourceFile] = []
            let fullScan = paths == nil || oldScope != scope || rebuild
            if fullScan {
                for source in sources {
                    try Task.checkCancellation()
                    allFiles += try source.discover()
                }
            } else {
                for path in (paths ?? []).sorted() {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try await database.deleteSource(path: url.path)
                    } else if let (_, file, _) = classify(url: url) { allFiles.append(file) }
                }
            }
            // A stable order and finite discovered set make progress comparable within a run.
            allFiles.sort { ($0.agent.rawValue, $0.url.path) < ($1.agent.rawValue, $1.url.path) }
            var seen: Set<String> = []
            allFiles = allFiles.filter { seen.insert($0.url.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
            status.totalFiles = allFiles.count
            var rootErrors: [String: String] = [:]
            for file in allFiles {
                try Task.checkCancellation()
                guard let source = source(for: file.agent),
                      let rootID = rootIDs["\(file.agent.rawValue):\(file.root.standardizedFileURL.path)"] else { continue }
                status.phase = .indexing
                status.agent = file.agent
                status.currentPath = file.url.path
                status.currentFileBytes = 0
                status.currentFileTotalBytes = (try? TraceFileIO.fingerprint(url: file.url).size) ?? 0
                status.sequence += 1
                await progress(status)
                do {
                    // The callback runs serially after committed batches, and never mutates the database.
                    let baseStatus = status
                    let outcome = try await process(file: file, using: source, rootID: rootID, scope: scope) { bytes, newlyCommitted, project in
                        var update = baseStatus
                        update.currentFileBytes = bytes
                        update.projectName = project
                        update.committedBytes += newlyCommitted
                        await progress(update)
                    }
                    if outcome.changed { status.indexedFiles += 1 } else { status.unchangedFiles += 1 }
                    status.committedBytes += outcome.committedBytes
                } catch is CancellationError { throw CancellationError() }
                catch {
                    status.failedFiles += 1
                    status.error = error.localizedDescription
                    try? await database.recordSourceError(path: file.url.path, error: error.localizedDescription)
                    rootErrors["\(file.agent.rawValue):\(file.root.standardizedFileURL.path)"] = error.localizedDescription
                }
                status.completedFiles += 1
            }
            try Task.checkCancellation()
            if fullScan {
                status.phase = .reconciling
                status.sequence += 1
                await progress(status)
                for source in sources {
                    let live = Set(allFiles.filter { $0.agent == source.agent }.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
                    for stored in try await database.paths(agent: source.agent) where !live.contains(stored.path) {
                        try Task.checkCancellation()
                        try await database.deleteSource(id: stored.id)
                    }
                    for root in source.roots {
                        if let rootID = rootIDs[root.id] { try await database.recordRootScan(rootID: rootID, error: rootErrors[root.id]) }
                    }
                }
            }
            status.phase = .aggregating
            status.sequence += 1
            await progress(status)
            if status.indexedFiles > 0 || fullScan || !(paths ?? []).isEmpty {
                try await database.rebuildUsageRollups()
            }
            try Task.checkCancellation()
            status.phase = .complete
            status.currentPath = nil
            status.agent = nil
        } catch is CancellationError {
            status.phase = .cancelled
        } catch {
            status.phase = .failed
            status.error = error.localizedDescription
        }
        status.sequence += 1
        await progress(status)
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

    public func failures(for session: SessionSummary) async throws -> [SessionFailure] {
        var failures = try await database.failures(sessionID: session.id)
        let summaries = try await database.messages(sessionID: session.id)
        for summary in summaries where summary.hasError {
            try Task.checkCancellation()
            guard !failures.contains(where: { $0.locator == summary.locator }) else { continue }
            let message = try await hydrate(summary)
            failures.append(.init(timestampMilliseconds: summary.timestampMilliseconds,
                kind: message.toolName == nil && message.sections.toolOutput.isEmpty ? "failed message" : "failed tool",
                toolName: message.toolName,
                detail: message.sections.toolOutput.isEmpty ? message.sections.prose : message.sections.toolOutput,
                locator: summary.locator))
        }
        // Old event-only sessions stored just a boolean. Resolve them read-only, without reindexing.
        if failures.isEmpty, session.hadError,
           let (source, file, _) = classify(url: URL(fileURLWithPath: session.sourcePath)) {
            for try await record in source.records(in: file, from: 0) {
                try Task.checkCancellation()
                if case .event(let event) = record {
                    failures.append(.init(timestampMilliseconds: event.timestampMilliseconds,
                        kind: event.kind.rawValue, toolName: nil,
                        detail: event.detail ?? "The source recorded an error without an explanation.", locator: event.locator))
                }
            }
        }
        return failures.sorted { $0.timestampMilliseconds > $1.timestampMilliseconds }
    }

    private func process(
        file: DiscoveredSourceFile,
        using source: any SessionSource,
        rootID: Int64,
        scope: IndexScope,
        attempt: Int = 0,
        committed: @escaping @Sendable (Int64, Int64, String?) async -> Void = { _, _, _ in }
    ) async throws -> (changed: Bool, committedBytes: Int64) {
        try Task.checkCancellation()
        let initialFingerprint = try TraceFileIO.fingerprint(url: file.url)
        var state = try await database.sourceState(path: file.url.path)

        if state == nil,
           let moved = try await database.sourceState(device: initialFingerprint.device, inode: initialFingerprint.inode) {
            try await database.moveSource(id: moved.id, rootID: rootID, path: file.url.path)
            state = try await database.sourceState(path: file.url.path)
        }

        if let state,
           state.device == initialFingerprint.device,
           state.inode == initialFingerprint.inode,
           state.size == initialFingerprint.size,
           state.modificationNanoseconds == initialFingerprint.modificationNanoseconds,
           state.scannedBytes == state.size,
           state.headLength == initialFingerprint.headLength,
           state.headHash == initialFingerprint.headHash {
            return (false, 0)
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
            await committed(initialFingerprint.size, initialFingerprint.size, nil)
            return (true, initialFingerprint.size)
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
        var projectName: String?
        for try await record in source.records(in: file, from: startOffset, through: initialFingerprint.size) {
            try Task.checkCancellation()
            if case .message(let message) = record, projectName == nil {
                projectName = ProjectCanonicalizer.canonicalProject(for: message.cwd).name
            }
            if case .checkpoint(let offset) = record { checkpoint = offset }
            batch.append(record)
            if batch.count >= 250, case .checkpoint = record {
                try await database.insert(records: batch, sourceFileID: sourceID, scope: scope)
                batch.removeAll(keepingCapacity: true)
                await committed(checkpoint, max(0, checkpoint - startOffset), projectName)
            }
        }
        if !batch.isEmpty {
            try await database.insert(records: batch, sourceFileID: sourceID, scope: scope)
            await committed(checkpoint, max(0, checkpoint - startOffset), projectName)
        }
        try Task.checkCancellation()

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
            return try await process(file: file, using: source, rootID: rootID, scope: scope, attempt: attempt + 1, committed: committed)
        }
        // Persist the fingerprint of the boundary actually consumed. Later appends remain detectable.
        try await database.finishSource(id: sourceID, fingerprint: initialFingerprint, scannedBytes: checkpoint)
        return (checkpoint > startOffset, max(0, checkpoint - startOffset))
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
            try Task.checkCancellation()
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
            _ = try await process(file: file, using: source, rootID: rootID, scope: scope, attempt: attempt + 1)
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
