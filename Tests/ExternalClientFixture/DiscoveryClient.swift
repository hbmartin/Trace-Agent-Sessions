import Foundation
import TraceCore

// Compiled without @testable to keep the discovery failure scope usable by clients.
struct ExternalDiscoverySource: SessionSource {
    let agent = AgentKind.claudeCode
    let roots: [SourceRoot]

    func discover() throws -> [DiscoveredSourceFile] { [] }

    func discoverResult(scopedTo paths: Set<String>?) throws -> DiscoveryResult {
        let requested = paths?.sorted().first ?? roots[0].url.path
        return DiscoveryResult(failures: [DiscoveryFailure(
            agent: agent, root: roots[0].url,
            path: "/unmappable/failed-directory", message: "unreadable",
            requestedScopePath: requested
        )])
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary)
    }

    func hydrate(
        fileURL: URL, format: SourceFormat, locator: RecordLocator
    ) throws -> HydratedMessage {
        throw NSError(domain: "ExternalDiscoverySource", code: 1)
    }
}

// Keep both scheduler entry points available without @testable imports.
func compileRebuildResetCallbackClient(_ scheduler: IndexScheduler) async {
    await scheduler.request(rebuild: true)
    await scheduler.request(rebuild: true, onRebuildReset: {})
    await scheduler.request(rebuild: true, onRebuildReset: {}, onRebuildDeferred: {}, automaticallyRetryReset: false)
}

func compileResolvedReleaseFunctionReference() {
    let wait: @Sendable (String, Int) async throws -> Void = TraceTestHooks.waitForRelease(path:timeoutMilliseconds:)
    _ = wait
}

// Additive navigation references remain usable without @testable or row-ID assumptions.
func compileNavigationReferenceClient(_ database: IndexDatabase, sessionID: Int64) async throws {
    let reference: SessionNavigationReference? = try await database.captureNavigationReference(sessionID: sessionID)
    if let reference { _ = try await database.resolveNavigationReference(reference) }
}

func compileOrdinaryCoverageClient(_ scheduler: IndexScheduler) async {
    await scheduler.request(rebuild: true, onRebuildReset: {}, onRebuildDeferred: {},
        automaticallyRetryReset: false, onOrdinaryWorkCompleted: {})
}

func compileGenerationOwnedNavigationClient(_ database: IndexDatabase, scheduler: IndexScheduler, sessionID: Int64) async throws {
    let generation: IndexContentGeneration = database.contentGeneration
    _ = try await database.session(id: sessionID, expectedGeneration: generation)
    _ = try await database.transcriptSnapshot(sessionID: sessionID, expectedGeneration: generation)
    let captured = try await database.captureNavigationReferences([sessionID: nil], expectedGeneration: generation)
    _ = try await database.captureNavigationReferences([sessionID: nil], expectedGeneration: generation, expectedReferences: captured)
    if let reference = captured[sessionID] { _ = reference.preservingAnchor(from: reference) }
    _ = try await database.resolveNavigationReferences(Dictionary(captured.values.map { ($0, Optional<Int>.none) }, uniquingKeysWith: { _, last in last }))
    await scheduler.requestOrdinaryRecovery(reconcile: true, onOrdinaryWorkCompleted: {})
}
