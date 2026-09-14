import Foundation

public struct CodexSource: SessionSource {
    public let agent = AgentKind.codex
    public let roots: [SourceRoot]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        roots = [SourceRoot(agent: .codex, url: root)]
    }

    public func discover() throws -> [DiscoveredSourceFile] {
        try discoverFiles(extensions: ["jsonl"]) { url in
            url.lastPathComponent.hasPrefix("rollout-") ? .codexJSONL : nil
        }
    }

    public func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64? = nil
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        var context = CodexContext(
            sessionID: file.url.deletingPathExtension().lastPathComponent,
            cwd: "Unknown", model: "unknown", timestamp: 0
        )
        var loadedHeader = offset == 0
        return ParsedRecordStream.jsonLines(url: file.url, from: offset, through: boundary) { line in
            if !loadedHeader {
                try loadCodexHeader(file.url, into: &context)
                loadedHeader = true
            }
            guard let object = try? JSONHelpers.object(from: line.data) else { return [] }
            return parseCodexRecord(
                object, context: &context,
                locator: .byteRange(offset: line.offset, length: Int64(line.data.count)),
                sourceKey: "\(line.offset)"
            )
        }
    }

    public func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        guard format == .codexJSONL,
              locator.kind == .byteRange,
              let offset = locator.offset,
              let length = locator.length
        else { throw SessionSourceError.unsupportedLocator }
        let data = try TraceFileIO.read(url: fileURL, offset: offset, length: length)
        let object = try JSONHelpers.object(from: data)
        var context = CodexContext(sessionID: "", cwd: "", model: "unknown", timestamp: 0)
        guard let record = parseCodexRecord(object, context: &context, locator: locator, sourceKey: "\(offset)")
            .compactMap({ record -> ParsedMessage? in
                if case .message(let message) = record { return message }
                return nil
            }).first
        else { throw SessionSourceError.malformedRecord("not a displayable Codex message") }
        return .init(role: record.role, sections: record.sections, toolName: record.toolName, hasError: record.hasError)
    }
}

private struct CodexContext {
    var sessionID: String
    var cwd: String
    var model: String
    var timestamp: Int64
}

private func loadCodexHeader(_ url: URL, into context: inout CodexContext) throws {
    let cursor = try JSONLineCursor(url: url, from: 0)
    while let line = try cursor.next() {
        guard let object = try? JSONHelpers.object(from: line.data),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else { continue }
        context.sessionID = payload["session_id"] as? String ?? payload["id"] as? String ?? context.sessionID
        context.cwd = payload["cwd"] as? String ?? context.cwd
        context.model = payload["model"] as? String ?? context.model
        context.timestamp = JSONHelpers.timestampMilliseconds(payload["timestamp"], fallback: context.timestamp)
        return
    }
}

private func parseCodexRecord(
    _ object: [String: Any],
    context: inout CodexContext,
    locator: RecordLocator,
    sourceKey: String
) -> [ParsedRecord] {
    let recordType = object["type"] as? String
    let payload = object["payload"] as? [String: Any] ?? [:]
    let timestamp = JSONHelpers.timestampMilliseconds(object["timestamp"], fallback: context.timestamp)

    if recordType == "session_meta" {
        context.sessionID = payload["session_id"] as? String ?? payload["id"] as? String ?? context.sessionID
        context.cwd = payload["cwd"] as? String ?? context.cwd
        context.model = payload["model"] as? String ?? context.model
        context.timestamp = JSONHelpers.timestampMilliseconds(payload["timestamp"], fallback: timestamp)
        return []
    }

    if recordType == "token_usage_record", let usageObject = payload["usage"] as? [String: Any] {
        let dedupe = payload["response_id"] as? String ?? "\(context.sessionID):\(sourceKey)"
        let usage = UsageObservation(
            dedupeKey: dedupe,
            model: payload["model"] as? String ?? context.model,
            inputTokens: JSONHelpers.int64(usageObject["input_tokens"]),
            outputTokens: JSONHelpers.int64(usageObject["output_tokens"]),
            cacheWriteTokens: JSONHelpers.int64(usageObject["cache_write_input_tokens"]),
            cacheReadTokens: JSONHelpers.int64(usageObject["cached_input_tokens"]),
            reasoningTokens: JSONHelpers.int64(usageObject["reasoning_output_tokens"])
        )
        return [.usage(.init(
            sourceKey: sourceKey,
            sessionExternalID: context.sessionID,
            cwd: context.cwd,
            timestampMilliseconds: timestamp,
            isSidechain: false,
            usage: usage
        ))]
    }

    if recordType == "event_msg" {
        let eventType = payload["type"] as? String ?? ""
        if eventType == "turn_aborted" || eventType == "task_failed" || eventType == "turn_failed" {
            return [.event(.init(
                sourceKey: sourceKey,
                sessionExternalID: context.sessionID,
                cwd: context.cwd,
                timestampMilliseconds: timestamp,
                kind: eventType == "turn_aborted" ? .aborted : .failed,
                detail: JSONHelpers.errorDescription(payload),
                locator: locator
            ))]
        }
        return []
    }

    guard recordType == "response_item" else { return [] }
    let itemType = payload["type"] as? String ?? ""
    let externalID = payload["id"] as? String ?? payload["call_id"] as? String
    var sections = MessageSections()
    var role = MessageRole.system
    var toolName: String?
    var hasError = ["failed", "error", "aborted"].contains((payload["status"] as? String ?? "").lowercased())

    switch itemType {
    case "message":
        let rawRole = payload["role"] as? String ?? "system"
        role = rawRole == "assistant" ? .assistant : (rawRole == "user" ? .user : .system)
        sections.prose = JSONHelpers.text(from: payload["content"])
    case "agent_message":
        role = .assistant
        sections.prose = payload["text"] as? String
            ?? payload["message"] as? String
            ?? JSONHelpers.text(from: payload["content"])
    case "reasoning":
        role = .reasoning
        sections.reasoning = JSONHelpers.text(from: payload["summary"])
    case "function_call", "custom_tool_call":
        role = .toolUse
        toolName = payload["name"] as? String ?? itemType
        let arguments = payload["arguments"] as? String
            ?? payload["input"] as? String
            ?? JSONHelpers.compactJSON(payload["input"])
        sections.toolInvocation = [toolName, arguments].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    case "function_call_output", "custom_tool_call_output":
        role = .toolResult
        sections.toolOutput = JSONHelpers.text(from: payload["output"])
        hasError = hasError || JSONHelpers.bool(payload["is_error"])
    default:
        return []
    }

    let message = ParsedMessage(
        sourceKey: externalID ?? sourceKey,
        externalID: externalID,
        sessionExternalID: context.sessionID,
        cwd: context.cwd,
        timestampMilliseconds: timestamp,
        role: role,
        sections: sections,
        locator: locator,
        model: context.model,
        hasError: hasError,
        toolName: toolName
    )
    return [.message(message)]
}
