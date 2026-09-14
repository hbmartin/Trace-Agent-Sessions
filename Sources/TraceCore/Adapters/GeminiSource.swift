import Foundation

public struct GeminiSource: SessionSource {
    public let agent = AgentKind.gemini
    public let roots: [SourceRoot]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")) {
        roots = [SourceRoot(agent: .gemini, url: root)]
    }

    public func discover() throws -> [DiscoveredSourceFile] {
        try discoverFiles(extensions: ["json", "jsonl"]) { url in
            guard url.deletingLastPathComponent().lastPathComponent == "chats",
                  url.lastPathComponent.hasPrefix("session-")
            else { return nil }
            return url.pathExtension.lowercased() == "jsonl" ? .geminiJSONL : .geminiJSON
        }
    }

    public func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64? = nil
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        if file.format == .geminiJSON {
            let state = GeminiSnapshotStream(file: file)
            return AsyncThrowingStream(unfolding: { try state.next() })
        }
        let metadata = geminiMetadata(for: file.url)
        return ParsedRecordStream.jsonLines(url: file.url, from: offset, through: boundary) { line in
            guard let root = try? JSONHelpers.object(from: line.data) else { return [] }
            let sessionID = root["sessionId"] as? String ?? metadata.sessionID
            return JSONDocumentScanner.objectRanges(in: line.data, arrayKey: "messages").compactMap { range in
                guard let object = try? JSONHelpers.object(from: line.data.subdata(in: range)) else { return nil }
                let absoluteOffset = line.offset + Int64(range.lowerBound)
                return parseGeminiMessage(
                    object, sessionID: sessionID, cwd: metadata.cwd,
                    fallbackTimestamp: metadata.timestamp + absoluteOffset,
                    locator: .byteRange(offset: absoluteOffset, length: Int64(range.count), key: object["id"] as? String),
                    sourceKey: object["id"] as? String ?? "\(absoluteOffset)"
                ).map { .message($0) }
            }
        }
    }

    public func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        guard locator.kind == .byteRange,
              let offset = locator.offset,
              let length = locator.length
        else { throw SessionSourceError.unsupportedLocator }
        let data = try TraceFileIO.read(url: fileURL, offset: offset, length: length)
        let object = try JSONHelpers.object(from: data)
        guard let message = parseGeminiMessage(
            object,
            sessionID: "",
            cwd: "",
            fallbackTimestamp: 0,
            locator: locator,
            sourceKey: locator.key ?? "\(offset)"
        ) else { throw SessionSourceError.malformedRecord("not a displayable Gemini message") }
        return .init(role: message.role, sections: message.sections, toolName: message.toolName, hasError: message.hasError)
    }
}

private func geminiMetadata(for fileURL: URL) -> (sessionID: String, cwd: String, timestamp: Int64) {
    let sessionID = fileURL.deletingPathExtension().lastPathComponent
    let projectDirectory = fileURL.deletingLastPathComponent().deletingLastPathComponent()
    let marker = projectDirectory.appendingPathComponent(".project_root")
    let cwd = (try? String(contentsOf: marker, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = (try? TraceFileIO.fingerprint(url: fileURL).modificationNanoseconds / 1_000_000)
        ?? Int64(Date().timeIntervalSince1970 * 1_000)
    return (sessionID, cwd?.isEmpty == false ? cwd! : projectDirectory.path, timestamp)
}

private func parseGeminiMessage(
    _ object: [String: Any],
    sessionID: String,
    cwd: String,
    fallbackTimestamp: Int64,
    locator: RecordLocator,
    sourceKey: String
) -> ParsedMessage? {
    guard let rawType = object["type"] as? String else { return nil }
    let role: MessageRole = rawType == "user" ? .user : .assistant
    var sections = MessageSections(prose: JSONHelpers.text(from: object["content"]))
    var toolName: String?
    var hasError = false

    if let thoughts = object["thoughts"] as? [[String: Any]] {
        sections.reasoning = thoughts.compactMap { thought in
            thought["description"] as? String ?? thought["subject"] as? String
        }.joined(separator: "\n")
    }

    if let calls = object["toolCalls"] as? [[String: Any]] {
        var invocations: [String] = []
        var outputs: [String] = []
        for call in calls {
            let name = call["name"] as? String ?? call["displayName"] as? String ?? "tool"
            toolName = toolName ?? name
            let arguments = JSONHelpers.compactJSON(call["args"])
            invocations.append([name, arguments].filter { !$0.isEmpty }.joined(separator: " "))
            outputs.append(JSONHelpers.text(from: call["result"]))
            let status = (call["status"] as? String ?? "").lowercased()
            hasError = hasError || ["error", "failed", "cancelled"].contains(status)
            if let result = call["result"] as? [[String: Any]] {
                for item in result {
                    if let response = (item["functionResponse"] as? [String: Any])?["response"] as? [String: Any],
                       response["error"] != nil {
                        hasError = true
                    }
                }
            }
        }
        sections.toolInvocation = invocations.joined(separator: "\n")
        sections.toolOutput = outputs.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    let externalID = object["id"] as? String
    let model = object["model"] as? String
    var usage: UsageObservation?
    if let tokens = object["tokens"] as? [String: Any], let model {
        usage = .init(
            dedupeKey: externalID ?? sourceKey,
            model: model,
            inputTokens: JSONHelpers.int64(tokens["input"]),
            outputTokens: JSONHelpers.int64(tokens["output"]),
            cacheReadTokens: JSONHelpers.int64(tokens["cached"]),
            reasoningTokens: JSONHelpers.int64(tokens["thoughts"])
        )
    }

    return .init(
        sourceKey: externalID ?? sourceKey,
        externalID: externalID,
        sessionExternalID: sessionID,
        cwd: cwd,
        timestampMilliseconds: JSONHelpers.timestampMilliseconds(object["timestamp"], fallback: fallbackTimestamp),
        role: role,
        sections: sections,
        locator: locator,
        model: model,
        hasError: hasError,
        toolName: toolName,
        usage: usage
    )
}

private final class GeminiSnapshotStream: @unchecked Sendable {
    let file: DiscoveredSourceFile
    var data: Data?
    var ranges: ArraySlice<Range<Int>> = []
    var sessionID = ""
    var cwd = ""
    var timestamp: Int64 = 0
    var ordinal: Int64 = 0
    var finished = false

    init(file: DiscoveredSourceFile) { self.file = file }

    func next() throws -> ParsedRecord? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        if data == nil {
            let loaded = try Data(contentsOf: file.url)
            let root = try JSONHelpers.object(from: loaded)
            let metadata = geminiMetadata(for: file.url)
            sessionID = root["sessionId"] as? String ?? metadata.sessionID
            cwd = metadata.cwd
            timestamp = metadata.timestamp
            ranges = ArraySlice(JSONDocumentScanner.objectRanges(in: loaded, arrayKey: "messages"))
            data = loaded
        }
        guard let data else { return nil }
        while let range = ranges.popFirst() {
            try Task.checkCancellation()
            ordinal += 1
            guard let object = try? JSONHelpers.object(from: data.subdata(in: range)) else { continue }
            if let message = parseGeminiMessage(
                object, sessionID: sessionID, cwd: cwd, fallbackTimestamp: timestamp + ordinal - 1,
                locator: .byteRange(offset: Int64(range.lowerBound), length: Int64(range.count), key: object["id"] as? String),
                sourceKey: object["id"] as? String ?? "\(range.lowerBound)"
            ) { return .message(message) }
        }
        finished = true
        self.data = nil
        return .checkpoint(Int64(data.count))
    }
}
