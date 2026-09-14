import Foundation

public protocol SessionSource: Sendable {
    var agent: AgentKind { get }
    var roots: [SourceRoot] { get }

    func discover() throws -> [DiscoveredSourceFile]
    func records(in file: DiscoveredSourceFile, from offset: Int64) -> AsyncThrowingStream<ParsedRecord, Error>
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage
}

public enum SessionSourceError: LocalizedError, Sendable {
    case unreadableFile(String)
    case malformedRecord(String)
    case unsupportedLocator
    case missingRecord(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path): "Unable to read \(path)"
        case .malformedRecord(let reason): "Malformed session record: \(reason)"
        case .unsupportedLocator: "The source adapter does not support this message locator"
        case .missingRecord(let key): "The source record \(key) no longer exists"
        }
    }
}

public extension SessionSource {
    func discoverFiles(
        extensions allowedExtensions: Set<String>,
        classify: (URL) -> SourceFormat?
    ) throws -> [DiscoveredSourceFile] {
        let manager = FileManager.default
        var files: [DiscoveredSourceFile] = []

        for root in roots where manager.fileExists(atPath: root.url.path) {
            guard let enumerator = manager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard allowedExtensions.contains(url.pathExtension.lowercased()),
                      let format = classify(url)
                else { continue }
                files.append(.init(agent: agent, root: root.url, url: url, format: format))
            }
        }

        return files
    }
}
