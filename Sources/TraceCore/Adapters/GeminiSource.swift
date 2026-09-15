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
        records(in: file, from: offset, through: boundary, initialSessionID: nil)
    }

    public func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        if file.format == .geminiJSON {
            let state = GeminiSnapshotStream(file: file)
            return AsyncThrowingStream(unfolding: { try state.next() })
        }
        let metadata = geminiMetadata(for: file.url)
        var currentSessionID = initialSessionID ?? metadata.sessionID
        var loadedContext = offset == 0 || initialSessionID != nil
        return ParsedRecordStream.jsonLines(url: file.url, from: offset, through: boundary) { line in
            if !loadedContext {
                currentSessionID = try GeminiJSONLSessionIdentity.id(before: offset, in: file.url)
                    ?? metadata.sessionID
                loadedContext = true
            }
            guard let root = try? JSONHelpers.object(from: line.data) else { return [] }
            var records: [ParsedRecord] = []
            if let explicitID = GeminiJSONLSessionIdentity.explicitID(in: root) {
                currentSessionID = explicitID
                records.append(.sessionContext(explicitID))
            }
            records += JSONDocumentScanner.objectRanges(in: line.data, arrayKey: "messages").compactMap { range in
                guard let object = try? JSONHelpers.object(from: line.data.subdata(in: range)) else { return nil }
                let absoluteOffset = line.offset + Int64(range.lowerBound)
                return parseGeminiMessage(
                    object, sessionID: currentSessionID, cwd: metadata.cwd,
                    fallbackTimestamp: metadata.timestamp + absoluteOffset,
                    locator: .byteRange(offset: absoluteOffset, length: Int64(range.count), key: object["id"] as? String),
                    sourceKey: object["id"] as? String ?? "\(absoluteOffset)"
                ).map { .message($0) }
            }
            return records
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

enum GeminiJSONLSessionIdentity {
    #if DEBUG
    private nonisolated(unsafe) static var prefixScans = 0
    private nonisolated(unsafe) static var delayedPrefixPath: String?
    private nonisolated(unsafe) static var prefixLineDelay: TimeInterval = 0
    private static let prefixScanLock = NSLock()
    static func resetPrefixScanCount() { prefixScanLock.withLock { prefixScans = 0 } }
    static var prefixScanCount: Int { prefixScanLock.withLock { prefixScans } }
    static func delayPrefixScan(path: String?, secondsPerLine: TimeInterval = 0) {
        prefixScanLock.withLock {
            delayedPrefixPath = path
            prefixLineDelay = secondsPerLine
        }
    }
    #endif

    static func explicitID(in root: [String: Any]) -> String? {
        func nonempty(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func id(_ object: [String: Any]) -> String? {
            nonempty(object["sessionId"])
                ?? nonempty(object["session_id"])
                ?? nonempty(object["sessionID"])
        }
        return id(root) ?? (root["$set"] as? [String: Any]).flatMap(id)
    }

    static func id(before offset: Int64, in url: URL) throws -> String? {
        #if DEBUG
        prefixScanLock.withLock { prefixScans += 1 }
        #endif
        let cursor = try JSONLineCursor(url: url, from: 0, through: offset)
        var inherited: String?
        while let line = try cursor.next() {
            try Task.checkCancellation()
            #if DEBUG
            let delay = prefixScanLock.withLock {
                delayedPrefixPath == url.path ? prefixLineDelay : 0
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            #endif
            guard let root = try? JSONHelpers.object(from: line.data) else { continue }
            inherited = explicitID(in: root) ?? inherited
        }
        try Task.checkCancellation()
        return inherited
    }
}

private func geminiMetadata(for fileURL: URL) -> (sessionID: String, cwd: String, timestamp: Int64) {
    let sessionID = fileURL.deletingPathExtension().lastPathComponent
    let projectDirectory = fileURL.deletingLastPathComponent().deletingLastPathComponent()
    let marker = projectDirectory.appendingPathComponent(".project_root")
    let cwd = (try? String(contentsOf: marker, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = TraceFileIO.modificationMilliseconds(url: fileURL)
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
    var sections = MessageSections(
        prose: JSONHelpers.text(from: object["content"]),
        hasNonTextContent: JSONHelpers.hasNonTextContent(object["content"])
    )
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
            sections.hasNonTextContent = sections.hasNonTextContent || JSONHelpers.hasNonTextContent(call["result"])
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

final class GeminiSnapshotStream: @unchecked Sendable {
    private enum Phase { case header, messages, tail, checkpoint, finished }

    let file: DiscoveredSourceFile
    private var handle: FileHandle?
    private var fileSize: Int64 = 0
    private var reachedEOF = false
    private var buffer: [UInt8] = []
    private var bufferOffset: Int64 = 0
    private var scanIndex = 0
    private var phase = Phase.header
    private var sessionID = ""
    private var cwd = ""
    private var timestamp: Int64 = 0
    private var ordinal: Int64 = 0
    private var objectStart: Int?
    private var objectDepth = 0
    private var objectInString = false
    private var objectEscaped = false
    private var tailObjectDepth = 1
    private var tailArrayDepth = 0
    private var tailInString = false
    private var tailEscaped = false
    private var rootClosed = false
    private var validationDocument = Data()
    private(set) var rootObject: [String: Any]?
    private(set) var currentMessageObject: [String: Any]?

    init(file: DiscoveredSourceFile) { self.file = file }

    deinit { try? handle?.close() }

    func next() throws -> ParsedRecord? {
        try Task.checkCancellation()
        try openIfNeeded()

        while true {
            switch phase {
            case .header:
                if let start = JSONDocumentScanner.arrayStart(in: Data(buffer), arrayKey: "messages") {
                    guard start <= 1_048_576 else {
                        throw SessionSourceError.malformedRecord("Gemini snapshot header exceeds 1 MiB")
                    }
                    let header = Data(buffer[0..<start])
                    sessionID = snapshotSessionID(in: header) ?? sessionID
                    validationDocument.append(contentsOf: buffer[0...start])
                    validationDocument.append(0x5D)
                    consume(start + 1)
                    phase = .messages
                    continue
                }
                guard buffer.count <= 1_048_576 else {
                    throw SessionSourceError.malformedRecord("Gemini snapshot header exceeds 1 MiB")
                }
                guard try readMore() else {
                    throw SessionSourceError.malformedRecord("Gemini snapshot is missing a messages array")
                }

            case .messages:
                if let objectRecord = try nextMessageObject() {
                    ordinal += 1
                    guard let object = try? JSONHelpers.object(from: objectRecord.data) else { continue }
                    currentMessageObject = object
                    if let message = parseGeminiMessage(
                        object, sessionID: sessionID, cwd: cwd, fallbackTimestamp: timestamp + ordinal - 1,
                        locator: .byteRange(
                            offset: objectRecord.offset, length: Int64(objectRecord.data.count),
                            key: object["id"] as? String
                        ),
                        sourceKey: object["id"] as? String ?? "\(objectRecord.offset)"
                    ) { return .message(message) }
                } else if phase == .messages {
                    throw SessionSourceError.malformedRecord("Gemini snapshot ended inside the messages array")
                }

            case .tail:
                try validateTail()
                phase = .checkpoint

            case .checkpoint:
                phase = .finished
                return .checkpoint(fileSize)

            case .finished:
                return nil
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let opened = try FileHandle(forReadingFrom: file.url)
        fileSize = Int64(try opened.seekToEnd())
        try opened.seek(toOffset: 0)
        handle = opened
        let metadata = geminiMetadata(for: file.url)
        sessionID = metadata.sessionID
        cwd = metadata.cwd
        timestamp = metadata.timestamp
    }

    private func readMore() throws -> Bool {
        try Task.checkCancellation()
        guard !reachedEOF, let handle else { return false }
        guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
            reachedEOF = true
            return false
        }
        buffer.append(contentsOf: chunk)
        return true
    }

    private func nextMessageObject() throws -> (data: Data, offset: Int64)? {
        while true {
            while scanIndex < buffer.count {
                try Task.checkCancellation()
                let byte = buffer[scanIndex]
                if objectStart == nil {
                    if byte.isJSONWhitespace || byte == 0x2C {
                        scanIndex += 1
                        continue
                    }
                    if byte == 0x5D {
                        consume(scanIndex + 1)
                        phase = .tail
                        return nil
                    }
                    guard byte == 0x7B else {
                        throw SessionSourceError.malformedRecord("Gemini messages must contain JSON objects")
                    }
                    objectStart = scanIndex
                    objectDepth = 1
                    objectInString = false
                    objectEscaped = false
                    scanIndex += 1
                    continue
                }

                if objectInString {
                    if objectEscaped {
                        objectEscaped = false
                    } else if byte == 0x5C {
                        objectEscaped = true
                    } else if byte == 0x22 {
                        objectInString = false
                    }
                } else if byte == 0x22 {
                    objectInString = true
                } else if byte == 0x7B {
                    objectDepth += 1
                } else if byte == 0x7D {
                    objectDepth -= 1
                    if objectDepth == 0, let start = objectStart {
                        let end = scanIndex + 1
                        let offset = bufferOffset + Int64(start)
                        let data = Data(buffer[start..<end])
                        consume(end)
                        objectStart = nil
                        objectInString = false
                        objectEscaped = false
                        return (data, offset)
                    }
                }
                scanIndex += 1
            }
            if objectStart == nil, scanIndex > 0 { consume(scanIndex) }
            guard try readMore() else { return nil }
        }
    }

    private func validateTail() throws {
        while true {
            while scanIndex < buffer.count {
                try Task.checkCancellation()
                let byte = buffer[scanIndex]
                scanIndex += 1
                validationDocument.append(byte)
                if rootClosed {
                    guard byte.isJSONWhitespace else {
                        throw SessionSourceError.malformedRecord("Gemini snapshot has data after its root object")
                    }
                    continue
                }
                if tailInString {
                    if tailEscaped {
                        tailEscaped = false
                    } else if byte == 0x5C {
                        tailEscaped = true
                    } else if byte == 0x22 {
                        tailInString = false
                    }
                    continue
                }
                switch byte {
                case 0x22: tailInString = true
                case 0x7B: tailObjectDepth += 1
                case 0x7D:
                    tailObjectDepth -= 1
                    if tailObjectDepth == 0 && tailArrayDepth == 0 { rootClosed = true }
                    if tailObjectDepth < 0 {
                        throw SessionSourceError.malformedRecord("Gemini snapshot has an unexpected closing brace")
                    }
                case 0x5B: tailArrayDepth += 1
                case 0x5D:
                    tailArrayDepth -= 1
                    if tailArrayDepth < 0 {
                        throw SessionSourceError.malformedRecord("Gemini snapshot has an unexpected closing bracket")
                    }
                default: break
                }
            }
            if scanIndex > 0 { consume(scanIndex) }
            if try readMore() { continue }
            guard rootClosed, tailObjectDepth == 0, tailArrayDepth == 0, !tailInString else {
                throw SessionSourceError.malformedRecord("Gemini snapshot ended before its root object was complete")
            }
            guard let object = try JSONSerialization.jsonObject(with: validationDocument) as? [String: Any] else {
                throw SessionSourceError.malformedRecord("Gemini snapshot is not a valid JSON object")
            }
            rootObject = object
            return
        }
    }

    private func consume(_ count: Int) {
        guard count > 0 else { return }
        buffer.removeFirst(count)
        bufferOffset += Int64(count)
        scanIndex = max(0, scanIndex - count)
    }

    private func snapshotSessionID(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"\"sessionId\"\s*:\s*(\"(?:\\.|[^\"\\])*\")"#
              )
        else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: whole),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let literal = String(text[range])
        guard let encoded = "[\(literal)]".data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: encoded) as? [String]
        else { return nil }
        return values.first
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
