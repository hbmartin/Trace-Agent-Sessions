import Foundation

public struct ClaudeCodeSource: SessionSource {
    public let agent = AgentKind.claudeCode
    public let roots: [SourceRoot]

    public init(roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")]) {
        self.roots = SourceRoot.deduplicated(roots.enumerated().map { index, url in
            SourceRoot(agent: .claudeCode, url: url, isDefault: index == 0)
        })
    }

    public func discover() throws -> [DiscoveredSourceFile] {
        try discoverFiles(extensions: ["jsonl"]) { sourceFormat(for: $0, agent: agent) }
    }

    public func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile] {
        try discoverFiles(extensions: ["jsonl"], scopedTo: paths) {
            sourceFormat(for: $0, agent: agent)
        }
    }

    public func discoverResult(scopedTo paths: Set<String>?) throws -> DiscoveryResult {
        try discoverFilesResult(extensions: ["jsonl"], scopedTo: paths) {
            sourceFormat(for: $0, agent: agent)
        }
    }

    public func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64? = nil
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let fallback = TraceFileIO.modificationMilliseconds(url: file.url)
        return ParsedRecordStream.jsonLines(url: file.url, from: offset, through: boundary) { line in
            guard let object = try? JSONHelpers.object(from: line.data),
                  let message = parseClaudeMessage(
                    object,
                    fallbackSessionID: file.url.deletingPathExtension().lastPathComponent,
                    fallbackTimestamp: fallback + line.offset,
                    locator: .byteRange(offset: line.offset, length: Int64(line.data.count)),
                    sourceKey: "\(line.offset)"
                  ) else { return [] }
            return [.message(message)]
        }
    }

    public func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary)
    }

    public func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        guard format == .claudeJSONL,
              locator.kind == .byteRange,
              let offset = locator.offset,
              let length = locator.length
        else { throw SessionSourceError.unsupportedLocator }
        let data = try TraceFileIO.read(url: fileURL, offset: offset, length: length)
        let object = try JSONHelpers.object(from: data)
        guard let message = parseClaudeMessage(
            object,
            fallbackSessionID: fileURL.deletingPathExtension().lastPathComponent,
            fallbackTimestamp: 0,
            locator: locator,
            sourceKey: "\(offset)"
        ) else { throw SessionSourceError.malformedRecord("not a displayable Claude message") }
        return .init(role: message.role, sections: message.sections, toolName: message.toolName, hasError: message.hasError)
    }
}

private func parseClaudeMessage(
    _ object: [String: Any],
    fallbackSessionID: String,
    fallbackTimestamp: Int64,
    locator: RecordLocator,
    sourceKey: String
) -> ParsedMessage? {
    guard let type = object["type"] as? String,
          ["user", "assistant", "system"].contains(type)
    else { return nil }

    let envelope = object["message"] as? [String: Any]
    let content = envelope?["content"] ?? object["content"]
    var sections = MessageSections(hasNonTextContent: JSONHelpers.hasNonTextContent(content))
    var toolName: String?
    var hasError = JSONHelpers.bool(object["is_error"]) || JSONHelpers.bool(object["isError"])

    if let string = content as? String {
        sections.prose = string
    } else if let blocks = content as? [Any] {
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "text", "input_text", "output_text":
                sections.prose = append(sections.prose, block["text"] as? String)
            case "thinking", "reasoning":
                sections.reasoning = append(sections.reasoning, block["thinking"] as? String ?? block["text"] as? String)
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                toolName = toolName ?? name
                sections.toolInvocation = append(
                    sections.toolInvocation,
                    [name, JSONHelpers.compactJSON(block["input"])].filter { !$0.isEmpty }.joined(separator: " ")
                )
            case "tool_result":
                sections.toolOutput = append(sections.toolOutput, JSONHelpers.text(from: block["content"]))
                hasError = hasError || JSONHelpers.bool(block["is_error"]) || JSONHelpers.bool(block["isError"])
            default:
                continue
            }
        }
    }

    let role: MessageRole
    if type == "system" {
        role = .system
    } else if !sections.toolOutput.isEmpty, sections.prose.isEmpty {
        role = .toolResult
    } else if !sections.toolInvocation.isEmpty, sections.prose.isEmpty {
        role = .toolUse
    } else {
        role = type == "assistant" ? .assistant : .user
    }

    let model = envelope?["model"] as? String
    let lineID = object["uuid"] as? String
    let responseID = envelope?["id"] as? String
    let externalID = lineID ?? responseID
    let usage = claudeUsage(
        envelope?["usage"] as? [String: Any],
        model: model,
        dedupeKey: responseID ?? lineID ?? sourceKey
    )

    return .init(
        sourceKey: lineID ?? responseID ?? sourceKey,
        externalID: externalID,
        sessionExternalID: object["sessionId"] as? String ?? object["session_id"] as? String ?? fallbackSessionID,
        cwd: object["cwd"] as? String ?? "Unknown",
        timestampMilliseconds: JSONHelpers.timestampMilliseconds(object["timestamp"], fallback: fallbackTimestamp),
        role: role,
        sections: sections,
        locator: locator,
        model: model,
        isSidechain: JSONHelpers.bool(object["isSidechain"]),
        hasError: hasError,
        toolName: toolName,
        usage: usage
    )
}

private func claudeUsage(
    _ object: [String: Any]?,
    model: String?,
    dedupeKey: String
) -> UsageObservation? {
    guard let object, let model else { return nil }
    return .init(
        dedupeKey: dedupeKey,
        model: model,
        inputTokens: JSONHelpers.int64(object["input_tokens"]),
        outputTokens: JSONHelpers.int64(object["output_tokens"]),
        cacheWriteTokens: JSONHelpers.int64(object["cache_creation_input_tokens"]),
        cacheReadTokens: JSONHelpers.int64(object["cache_read_input_tokens"]),
        reasoningTokens: JSONHelpers.int64((object["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
    )
}

private func append(_ existing: String, _ addition: String?) -> String {
    guard let addition, !addition.isEmpty else { return existing }
    return existing.isEmpty ? addition : existing + "\n" + addition
}
