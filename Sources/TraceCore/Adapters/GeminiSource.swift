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
        in file: DiscoveredSourceFile,
        from offset: Int64
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    let metadata = geminiMetadata(for: file.url)
                    if file.format == .geminiJSON {
                        let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
                        let root = try JSONHelpers.object(from: data)
                        let sessionID = root["sessionId"] as? String ?? metadata.sessionID
                        let ranges = JSONDocumentScanner.objectRanges(in: data, arrayKey: "messages")
                        for (index, range) in ranges.enumerated() {
                            let objectData = data.subdata(in: range)
                            guard let messageObject = try? JSONHelpers.object(from: objectData) else { continue }
                            let locator = RecordLocator.byteRange(
                                offset: Int64(range.lowerBound),
                                length: Int64(range.count),
                                key: messageObject["id"] as? String
                            )
                            if let message = parseGeminiMessage(
                                messageObject,
                                sessionID: sessionID,
                                cwd: metadata.cwd,
                                fallbackTimestamp: metadata.timestamp + Int64(index),
                                locator: locator,
                                sourceKey: messageObject["id"] as? String ?? "\(range.lowerBound)"
                            ) {
                                continuation.yield(.message(message))
                            }
                        }
                        continuation.yield(.checkpoint(Int64(data.count)))
                    } else {
                        let checkpoint = try JSONLineReader.forEachCompleteLine(at: file.url, from: offset) { line in
                            guard let root = try? JSONHelpers.object(from: line.data) else { return }
                            let sessionID = root["sessionId"] as? String ?? metadata.sessionID
                            let ranges = JSONDocumentScanner.objectRanges(in: line.data, arrayKey: "messages")
                            for (index, range) in ranges.enumerated() {
                                let objectData = line.data.subdata(in: range)
                                guard let messageObject = try? JSONHelpers.object(from: objectData) else { continue }
                                let absoluteOffset = line.offset + Int64(range.lowerBound)
                                let locator = RecordLocator.byteRange(
                                    offset: absoluteOffset,
                                    length: Int64(range.count),
                                    key: messageObject["id"] as? String
                                )
                                if let message = parseGeminiMessage(
                                    messageObject,
                                    sessionID: sessionID,
                                    cwd: metadata.cwd,
                                    fallbackTimestamp: metadata.timestamp + absoluteOffset + Int64(index),
                                    locator: locator,
                                    sourceKey: messageObject["id"] as? String ?? "\(absoluteOffset)"
                                ) {
                                    continuation.yield(.message(message))
                                }
                            }
                        }
                        continuation.yield(.checkpoint(checkpoint))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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
