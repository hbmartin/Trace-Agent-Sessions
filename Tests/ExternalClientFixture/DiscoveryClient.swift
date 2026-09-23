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
