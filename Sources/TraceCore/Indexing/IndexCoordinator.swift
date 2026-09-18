import Foundation

public enum IndexActivity: String, Equatable, Sendable {
    case initialBuild
    case launchCatchUp
    case launchReconciliation
    case cachedLaunch
    case fileChanges
    case subtreeRecovery
    case rootRecovery
    case eventStreamRecovery
    case safetyVerification
    case rebuild
    case scopeChange
}

public struct IndexProgress: Sendable {
    public enum Phase: String, Sendable {
        case waiting, discovering, indexing, reconciling, aggregating, complete, cancelled, failed
    }
    public var phase: Phase
    public var activity: IndexActivity = .initialBuild
    public var incremental: Bool = false
    public var agent: AgentKind?
    public var completedFiles: Int
    public var totalFiles: Int
    public var indexedFiles: Int = 0
    public var indexChanged: Bool = false
    public var rollupsChanged: Bool = false
    public var passID = UUID()
    public var mutationRevision: Int = 0
    public var unchangedFiles: Int = 0
    public var failedFiles: Int = 0
    public var unresolvedFailedFiles: Int = 0
    public var committedBytes: Int64 = 0
    public var currentFileBytes: Int64 = 0
    public var currentFileTotalBytes: Int64 = 0
    public var projectName: String?
    public var currentPath: String?
    public var error: String?
    public var metadataWarning: String?
    public var rollupError: String?

    public init(phase: Phase, agent: AgentKind? = nil, completedFiles: Int = 0,
                totalFiles: Int = 0, currentPath: String? = nil, error: String? = nil) {
        self.phase = phase
        self.agent = agent
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentPath = currentPath
        self.error = error
    }
}

private actor PassMutationTracker {
    private var revision = 0
    func markChanged() { revision += 1 }
    func version() -> Int { revision }
    func hasChanges() -> Bool { revision > 0 }
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
    private struct CodexNameCacheEntry {
        let names: [String: String]
        let loadedAt: ContinuousClock.Instant
    }
    private var codexNameCache: [String: CodexNameCacheEntry] = [:]

    public init(database: IndexDatabase, sources: [any SessionSource]) {
        self.database = database
        self.sources = sources
    }

    private func codexNames(directory: URL, force: Bool = false) async -> [String: String] {
        let key = directory.standardizedFileURL.path
        if !force, let cached = codexNameCache[key],
           cached.loadedAt.duration(to: .now) < .seconds(30) {
            return cached.names
        }
        let names = await Self.loadCodexNames(directory: directory)
        codexNameCache[key] = .init(names: names, loadedAt: .now)
        return names
    }

    public func indexAll(scope: IndexScope, rebuild: Bool = false,
                         activity: IndexActivity? = nil,
                         progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async {
        _ = await indexAllResult(
            scope: scope, rebuild: rebuild, activity: activity, progress: progress
        )
    }

    func indexAllResult(scope: IndexScope, rebuild: Bool = false,
                        activity: IndexActivity? = nil,
                        progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async -> IndexProgress {
        await gate.acquire()
        let result = await run(
            scope: scope, paths: nil, reconciliationPaths: [], rebuild: rebuild,
            activity: activity ?? (rebuild ? .rebuild : .initialBuild), progress: progress
        )
        await gate.release()
        return result
    }

    public func refresh(paths: Set<String>, scope: IndexScope,
                        activity: IndexActivity = .fileChanges,
                        progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async {
        _ = await refreshResult(
            paths: paths, scope: scope, activity: activity, progress: progress
        )
    }

    func refreshResult(paths: Set<String>, scope: IndexScope,
                       activity: IndexActivity = .fileChanges,
                       progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async -> IndexProgress {
        await gate.acquire()
        let result = await run(
            scope: scope, paths: paths, reconciliationPaths: [], rebuild: false,
            activity: activity, progress: progress
        )
        await gate.release()
        return result
    }

    @discardableResult
    public func reconcile(paths: Set<String>, changedPaths: Set<String> = [], scope: IndexScope,
                          activity: IndexActivity,
                          progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async -> IndexProgress {
        await gate.acquire()
        let result = await run(
            scope: scope, paths: changedPaths, reconciliationPaths: paths,
            rebuild: false, activity: activity, progress: progress
        )
        await gate.release()
        return result
    }

    private func run(scope: IndexScope, paths: Set<String>?, reconciliationPaths: Set<String>,
                     rebuild: Bool, activity: IndexActivity,
                     progress: @escaping @Sendable (IndexProgress) async -> Void) async -> IndexProgress {
        var status = IndexProgress(phase: .discovering)
        status.activity = activity
        status.incremental = paths != nil || !reconciliationPaths.isEmpty
        let mutations = PassMutationTracker()
        status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount()) ?? 0
        do {
            try Task.checkCancellation()
            let oldScope = try await database.storedIndexScope()
            if rebuild || oldScope != scope {
                try await database.clearIndex()
                await mutations.markChanged()
            }
            try await database.setIndexScope(scope)
            status.mutationRevision = await mutations.version()
            await progress(status)
            var rootIDs: [String: Int64] = [:]
            for source in sources {
                for root in source.roots { rootIDs[root.id] = try await database.register(root: root) }
            }
            var allFiles: [DiscoveredSourceFile] = []
            let fullScan = (paths == nil && reconciliationPaths.isEmpty) || oldScope != scope || rebuild
            if oldScope != scope && !rebuild { status.activity = .scopeChange }
            let refreshCodexNames = fullScan || (paths ?? []).contains {
                TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: $0))
            }
            if refreshCodexNames { codexNameCache.removeAll() }
            var missingPaths: [String] = []
            if fullScan {
                for source in sources {
                    try Task.checkCancellation()
                    allFiles += try source.discover()
                }
            } else {
                if !reconciliationPaths.isEmpty {
                    for source in sources {
                        try Task.checkCancellation()
                        allFiles += try source.discover(scopedTo: reconciliationPaths)
                    }
                }
                for path in (paths ?? []).sorted() {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: TraceFileIO.canonicalPath(path).path)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        missingPaths.append(url.path)
                    } else if let (_, file, _) = classify(url: url) { allFiles.append(file) }
                }
            }
            // A stable order and finite discovered set make progress comparable within a run.
            allFiles.sort { ($0.agent.rawValue, $0.url.path) < ($1.agent.rawValue, $1.url.path) }
            var seen: Set<String> = []
            allFiles = allFiles.filter { seen.insert(TraceFileIO.canonicalPath($0.url.path).comparisonKey).inserted }
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
                status.mutationRevision = await mutations.version()
                await progress(status)
                var shouldRefreshMissingCodexTitle = false
                var needsFailureRecount = false
                do {
                    // The callback runs serially after committed batches, and never mutates the database.
                    let baseStatus = status
                    let outcome = try await process(
                        file: file, using: source, rootID: rootID, scope: scope,
                        mutation: { await mutations.markChanged() }
                    ) { bytes, newlyCommitted, project in
                        var update = baseStatus
                        update.currentFileBytes = bytes
                        update.projectName = project
                        update.committedBytes += newlyCommitted
                        update.mutationRevision = await mutations.version()
                        await progress(update)
                    }
                    let metadataChanged = try await refreshMetadata(file: file)
                    if metadataChanged { await mutations.markChanged() }
                    if outcome.hadRecordedError,
                       try await database.clearSourceError(path: file.url.path) {
                        needsFailureRecount = true
                    }
                    shouldRefreshMissingCodexTitle = !fullScan && file.agent == .codex
                        && (outcome.changed || metadataChanged)
                    if outcome.changed { status.indexedFiles += 1 } else { status.unchangedFiles += 1 }
                    status.committedBytes += outcome.committedBytes
                } catch is CancellationError { throw CancellationError() }
                catch {
                    status.failedFiles += 1
                    needsFailureRecount = true
                    status.error = error.localizedDescription
                    try? await database.recordSourceError(
                        file: file, rootID: rootID, error: error.localizedDescription
                    )
                    rootErrors["\(file.agent.rawValue):\(file.root.standardizedFileURL.path)"] = error.localizedDescription
                }
                if shouldRefreshMissingCodexTitle {
                    do {
                        if let state = try await database.sourceState(path: file.url.path),
                           try await database.hasUntitledCodexSessions(sourceID: state.id) {
                            let names = await codexNames(directory: file.root.deletingLastPathComponent())
                            if try await database.updateCodexNames(
                                names, root: file.root, sourceID: state.id, onlyMissing: true
                            ) { await mutations.markChanged() }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { status.metadataWarning = "Codex title lookup: \(error.localizedDescription)" }
                }
                status.completedFiles += 1
                if needsFailureRecount {
                    status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount())
                        ?? status.unresolvedFailedFiles
                }
                status.mutationRevision = await mutations.version()
                await progress(status)
            }
            try Task.checkCancellation()
            if !missingPaths.isEmpty {
                status.phase = .reconciling
                await progress(status)
                for path in missingPaths {
                    try Task.checkCancellation()
                    if try await database.sourceState(path: path) != nil {
                        try await database.deleteSource(path: path)
                        await mutations.markChanged()
                    }
                }
                status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount())
                    ?? status.unresolvedFailedFiles
                status.mutationRevision = await mutations.version()
                await progress(status)
            }
            if fullScan {
                status.phase = .reconciling
                await progress(status)
                for source in sources {
                    let live = Set(allFiles.filter { $0.agent == source.agent }
                        .map { TraceFileIO.canonicalPath($0.url.path).comparisonKey })
                    for stored in try await database.paths(agent: source.agent)
                    where !live.contains(TraceFileIO.canonicalPath(stored.path).comparisonKey) {
                        try Task.checkCancellation()
                        try await database.deleteSource(id: stored.id)
                        await mutations.markChanged()
                    }
                    for root in source.roots {
                        if let rootID = rootIDs[root.id] { try await database.recordRootScan(rootID: rootID, error: rootErrors[root.id]) }
                    }
                }
                status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount())
                    ?? status.unresolvedFailedFiles
            } else if !reconciliationPaths.isEmpty {
                status.phase = .reconciling
                await progress(status)
                let scopes = reconciliationPaths.map(TraceFileIO.canonicalPath)
                let live = Set(allFiles.map { TraceFileIO.canonicalPath($0.url.path).comparisonKey })
                for source in sources {
                    for stored in try await database.paths(agent: source.agent) {
                        try Task.checkCancellation()
                        let storedPath = TraceFileIO.canonicalPath(stored.path)
                        guard scopes.contains(where: { $0.contains(storedPath) }),
                              !live.contains(storedPath.comparisonKey) else { continue }
                        try await database.deleteSource(id: stored.id)
                        await mutations.markChanged()
                    }
                    for root in source.roots {
                        let canonicalRoot = TraceFileIO.canonicalPath(root.url.path)
                        guard scopes.contains(where: { $0.intersects(canonicalRoot) }),
                              let rootID = rootIDs[root.id] else { continue }
                        try await database.recordRootScan(rootID: rootID, error: rootErrors[root.id])
                    }
                }
                status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount())
                    ?? status.unresolvedFailedFiles
            }
            for source in sources where source.agent == .codex && refreshCodexNames {
                for root in source.roots {
                    do {
                        let names = await codexNames(directory: root.url.deletingLastPathComponent(), force: fullScan)
                        if try await database.updateCodexNames(names, root: root.url) {
                            await mutations.markChanged()
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { status.metadataWarning = "Codex title lookup: \(error.localizedDescription)" }
                }
            }
            status.phase = .aggregating
            status.mutationRevision = await mutations.version()
            await progress(status)
            do { status.rollupsChanged = try await database.rebuildUsageRollupsIfDirty() }
            catch is CancellationError { throw CancellationError() }
            catch { status.rollupError = error.localizedDescription }
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
        status.indexChanged = await mutations.hasChanges()
        status.mutationRevision = await mutations.version()
        status.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount())
            ?? status.unresolvedFailedFiles
        await progress(status)
        return status
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
        if session.hadError, try await database.needsLegacyFailureScan(sessionID: session.id),
           let (source, file, _) = classify(url: URL(fileURLWithPath: session.sourcePath)) {
            for try await record in source.records(in: file, from: 0) {
                try Task.checkCancellation()
                if case .event(let event) = record {
                    let failure = SessionFailure(timestampMilliseconds: event.timestampMilliseconds,
                        kind: event.kind.rawValue, toolName: nil,
                        detail: event.detail ?? "The source recorded an error without an explanation.", locator: event.locator)
                    let duplicate = failures.contains {
                        if let locator = failure.locator { return $0.locator == locator }
                        return $0.timestampMilliseconds == failure.timestampMilliseconds
                            && $0.kind == failure.kind && $0.detail == failure.detail
                    }
                    if !duplicate { failures.append(failure) }
                }
            }
        }
        return failures.sorted { $0.timestampMilliseconds > $1.timestampMilliseconds }
    }

    private func refreshMetadata(file: DiscoveredSourceFile) async throws -> Bool {
        guard let state = try await database.sourceState(path: file.url.path) else { return false }
        let storedRevision = try await database.metadataRevision(sourceID: state.id)
        let stored = storedRevision.flatMap(MetadataRevision.init)
        if stored?.version == 2,
           stored?.contentGeneration == state.contentGeneration,
           stored?.checkpoint == state.scannedBytes {
            return false
        }
        let canMerge = file.format != .geminiJSON
            && stored?.version == 2
            && stored?.contentGeneration == state.contentGeneration
            && (stored?.checkpoint ?? -1) >= 0
            && (stored?.checkpoint ?? .max) <= state.scannedBytes
        let startOffset = canMerge ? stored?.checkpoint ?? 0 : 0
        let mode: MetadataUpdateMode = canMerge ? .merge : .replace
        let initialSessionID: String?
        if !canMerge { initialSessionID = nil }
        else if file.format == .geminiJSONL {
            initialSessionID = state.metadataSessionID
        } else {
            initialSessionID = try await database.metadataSessionContext(sourceID: state.id, before: startOffset)
        }
        let before = try TraceFileIO.fingerprint(url: file.url)
        guard before.size == state.size, before.modificationNanoseconds == state.modificationNanoseconds else { return false }
        let scan = try await Self.scanMetadata(
            file: file,
            from: startOffset,
            through: state.scannedBytes,
            initialSessionID: initialSessionID
        )
        guard before == (try TraceFileIO.fingerprint(url: file.url)) else { return false }
        let revision = "2:\(state.contentGeneration):\(scan.checkpoint)"
        return try await database.updateMetadata(sourceID: state.id, revision: revision, scan: scan, mode: mode)
    }

    private nonisolated static func scanMetadata(
        file: DiscoveredSourceFile,
        from offset: Int64,
        through boundary: Int64,
        initialSessionID: String?
    ) async throws -> SessionMetadataScan {
        let task = Task.detached(priority: .utility) {
            try SessionMetadataReader.scan(
                file: file,
                from: offset,
                through: boundary,
                initialSessionID: initialSessionID
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private nonisolated static func legacyGeminiSessionID(before offset: Int64, in url: URL) async throws -> String? {
        let task = Task.detached(priority: .utility) {
            try GeminiJSONLSessionIdentity.id(before: offset, in: url)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private nonisolated static func loadCodexNames(directory: URL) async -> [String: String] {
        let task = Task.detached(priority: .utility) { CodexSessionNames.load(directory: directory) }
        return await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
    }

    private func process(
        file: DiscoveredSourceFile,
        using source: any SessionSource,
        rootID: Int64,
        scope: IndexScope,
        attempt: Int = 0,
        mutation: @escaping @Sendable () async -> Void = {},
        committed: @escaping @Sendable (Int64, Int64, String?) async -> Void = { _, _, _ in }
    ) async throws -> (changed: Bool, committedBytes: Int64, hadRecordedError: Bool) {
        try Task.checkCancellation()
        let initialFingerprint = try TraceFileIO.fingerprint(url: file.url)
        var state = try await database.sourceState(path: file.url.path)
        var hadRecordedError = state?.hadRecordedError ?? false
        var promotedPlaceholder = false

        if let placeholder = state, placeholder.isPlaceholder {
            if let moved = try await database.movableSourceState(
                device: initialFingerprint.device, inode: initialFingerprint.inode,
                agent: file.agent, format: file.format, targetPath: file.url.path
            ) {
                try await database.replacePlaceholderWithMovedSource(
                    placeholderID: placeholder.id, movedID: moved.id,
                    rootID: rootID, path: file.url.path
                )
                hadRecordedError = hadRecordedError || moved.hadRecordedError
            } else {
                try await database.promotePlaceholder(
                    id: placeholder.id, rootID: rootID, file: file, fingerprint: initialFingerprint
                )
                promotedPlaceholder = true
            }
            await mutation()
            state = try await database.sourceState(path: file.url.path)
            hadRecordedError = hadRecordedError || (state?.hadRecordedError ?? false)
        } else if state == nil,
                  let moved = try await database.movableSourceState(
                    device: initialFingerprint.device, inode: initialFingerprint.inode,
                    agent: file.agent, format: file.format, targetPath: file.url.path
                  ) {
            try await database.moveSource(id: moved.id, rootID: rootID, path: file.url.path)
            hadRecordedError = moved.hadRecordedError
            await mutation()
            state = try await database.sourceState(path: file.url.path)
        }

        if let existing = state, existing.agent != file.agent || existing.format != file.format {
            try await database.deleteSource(id: existing.id)
            await mutation()
            state = nil
            hadRecordedError = false
        }

        if let state, !promotedPlaceholder,
           state.device == initialFingerprint.device,
           state.inode == initialFingerprint.inode,
           state.size == initialFingerprint.size,
           state.modificationNanoseconds == initialFingerprint.modificationNanoseconds,
           state.scannedBytes == state.size,
           state.headLength == initialFingerprint.headLength,
           state.headHash == initialFingerprint.headHash {
            return (false, 0, hadRecordedError)
        }

        // For small files the existing head digest covers the entire payload. This is a
        // trusted content hash, so an atomic save that only changed inode/mtime can update
        // its fingerprint without deleting and recreating otherwise identical messages.
        // Larger files deliberately stay on the cheap 4 KiB fingerprint path unless an
        // actual change requires parsing; hashing every large session would negate the cache.
        if let state, !promotedPlaceholder,
           state.size == initialFingerprint.size,
           state.scannedBytes == state.size,
           Int64(state.headLength) == state.size,
           Int64(initialFingerprint.headLength) == initialFingerprint.size,
           state.headHash == initialFingerprint.headHash {
            try await database.finishSource(
                id: state.id, fingerprint: initialFingerprint, scannedBytes: state.scannedBytes
            )
            return (false, 0, hadRecordedError)
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
                attempt: attempt,
                mutation: mutation
            )
            await committed(initialFingerprint.size, initialFingerprint.size, nil)
            return (true, initialFingerprint.size, hadRecordedError)
        }

        let sourceID: Int64
        let startOffset: Int64
        if let state {
            let comparison = try TraceFileIO.fingerprint(url: file.url, preferredHeadLength: state.headLength)
            let appendable = comparison.inode == state.inode
                && comparison.device == state.device
                && comparison.size >= state.scannedBytes
                && comparison.headHash == state.headHash
                && (comparison.size > state.size
                    || comparison.modificationNanoseconds == state.modificationNanoseconds)
            sourceID = state.id
            if promotedPlaceholder {
                startOffset = 0
            } else if appendable {
                startOffset = state.scannedBytes
            } else {
                try await database.replaceSourceContents(id: state.id)
                await mutation()
                startOffset = 0
            }
        } else {
            sourceID = try await database.createSource(rootID: rootID, file: file, fingerprint: initialFingerprint)
            startOffset = 0
        }

        var contentSessionID: String?
        if file.format == .geminiJSONL {
            let fallback = file.url.deletingPathExtension().lastPathComponent
            if startOffset == 0 { contentSessionID = fallback }
            else if let inherited = state?.contentSessionID { contentSessionID = inherited }
            else {
                contentSessionID = try await Self.legacyGeminiSessionID(before: startOffset, in: file.url)
                    ?? fallback
            }
        }
        var batch: [ParsedRecord] = []
        var checkpoint = startOffset
        var persistedCheckpoint = startOffset
        var completedLines = 0
        var lastProgress: ContinuousClock.Instant?
        var projectName: String?
        let testBatchDelay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_INDEX_BATCH_DELAY_MS", cappedAt: 5_000
        )
        for try await record in source.records(
            in: file, from: startOffset, through: initialFingerprint.size,
            initialSessionID: contentSessionID
        ) {
            try Task.checkCancellation()
            if case .sessionContext(let id) = record { contentSessionID = id }
            if case .message(let message) = record, projectName == nil {
                projectName = ProjectCanonicalizer.canonicalProject(for: message.cwd).name
            }
            if case .checkpoint(let offset) = record {
                checkpoint = offset
                completedLines += 1
            } else if case .sessionContext = record {
                // The inherited identity is committed with the next checkpoint.
            } else {
                batch.append(record)
            }
            if case .checkpoint = record, batch.count >= 250 || completedLines >= 250 {
                if persistedCheckpoint == startOffset, let testBatchDelay {
                    try await Task.sleep(for: .milliseconds(testBatchDelay))
                }
                let batchChanged = !batch.isEmpty
                try await database.insert(
                    records: batch, sourceFileID: sourceID, scope: scope,
                    checkpoint: checkpoint, contentSessionID: contentSessionID
                )
                batch.removeAll(keepingCapacity: true)
                completedLines = 0
                persistedCheckpoint = checkpoint
                if batchChanged { await mutation() }
                if lastProgress == nil || lastProgress!.duration(to: .now) >= .milliseconds(250) {
                    lastProgress = .now
                    await committed(checkpoint, max(0, checkpoint - startOffset), projectName)
                }
                if let testBatchDelay {
                    try await Task.sleep(for: .milliseconds(testBatchDelay))
                }
            }
        }
        if !batch.isEmpty || checkpoint > persistedCheckpoint {
            let batchChanged = !batch.isEmpty
            try await database.insert(
                records: batch, sourceFileID: sourceID, scope: scope,
                checkpoint: checkpoint, contentSessionID: contentSessionID
            )
            if batchChanged { await mutation() }
        }
        await committed(checkpoint, max(0, checkpoint - startOffset), projectName)
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
            await mutation()
            guard attempt < 2 else {
                throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
            }
            let retried = try await process(
                file: file, using: source, rootID: rootID, scope: scope,
                attempt: attempt + 1, mutation: mutation, committed: committed
            )
            return (
                retried.changed, retried.committedBytes,
                hadRecordedError || retried.hadRecordedError
            )
        }
        // Persist the fingerprint of the boundary actually consumed. Later appends remain detectable.
        try await database.finishSource(id: sourceID, fingerprint: initialFingerprint, scannedBytes: checkpoint)
        return (checkpoint > startOffset, max(0, checkpoint - startOffset), hadRecordedError)
    }

    private func processSnapshot(
        file: DiscoveredSourceFile,
        using source: any SessionSource,
        rootID: Int64,
        sourceID: Int64,
        initialFingerprint: SourceFingerprint,
        scope: IndexScope,
        attempt: Int,
        mutation: @escaping @Sendable () async -> Void
    ) async throws {
        var records: [ParsedRecord] = []
        var checkpoint: Int64 = 0
        do {
            for try await record in source.records(in: file, from: 0) {
                try Task.checkCancellation()
                if case .checkpoint(let offset) = record { checkpoint = offset }
                records.append(record)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let current = try? TraceFileIO.fingerprint(
                url: file.url,
                preferredHeadLength: initialFingerprint.headLength == 0 ? nil : initialFingerprint.headLength
            )
            guard current != initialFingerprint else { throw error }
            guard attempt < 2 else {
                throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
            }
            _ = try await process(
                file: file, using: source, rootID: rootID, scope: scope,
                attempt: attempt + 1, mutation: mutation
            )
            return
        }
        try Task.checkCancellation()
        guard checkpoint == initialFingerprint.size else {
            let current = try TraceFileIO.fingerprint(
                url: file.url,
                preferredHeadLength: initialFingerprint.headLength == 0 ? nil : initialFingerprint.headLength
            )
            if current != initialFingerprint {
                guard attempt < 2 else {
                    throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
                }
                _ = try await process(
                    file: file, using: source, rootID: rootID, scope: scope,
                    attempt: attempt + 1, mutation: mutation
                )
                return
            }
            throw SessionSourceError.malformedRecord("snapshot ended before a complete file checkpoint")
        }

        let finalFingerprint = try TraceFileIO.fingerprint(
            url: file.url,
            preferredHeadLength: initialFingerprint.headLength == 0 ? nil : initialFingerprint.headLength
        )
        guard finalFingerprint == initialFingerprint else {
            guard attempt < 2 else {
                throw SessionSourceError.unreadableFile("\(file.url.path) changed repeatedly while indexing")
            }
            _ = try await process(
                file: file, using: source, rootID: rootID, scope: scope,
                attempt: attempt + 1, mutation: mutation
            )
            return
        }

        try Task.checkCancellation()
        try await database.replaceSnapshotContents(
            id: sourceID,
            records: records,
            scope: scope,
            fingerprint: finalFingerprint,
            scannedBytes: checkpoint
        )
        await mutation()
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

private struct MetadataRevision {
    let version: Int
    let contentGeneration: Int64
    let checkpoint: Int64

    init?(_ stored: String) {
        let components = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let version = Int(components[0]),
              let contentGeneration = Int64(components[1]),
              let checkpoint = Int64(components[2]) else { return nil }
        self.version = version
        self.contentGeneration = contentGeneration
        self.checkpoint = checkpoint
    }
}
