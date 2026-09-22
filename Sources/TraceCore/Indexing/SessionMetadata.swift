import Foundation
import GRDB

/// Derived metadata is disposable and can be backfilled without rewriting message rows.
struct SessionMetadata: Sendable {
    var title: String?
    var titleIsExplicit = false
    var firstUserMessage: String?
    var hasPlan = false
}

struct SessionMetadataScan: Sendable {
    var sessions: [String: SessionMetadata]
    var checkpoint: Int64
    var finalSessionID: String? = nil
}

enum MetadataUpdateMode: Sendable {
    case replace
    case merge
}

enum SessionMetadataReader {
    private struct Accumulator {
        var explicitTitle: String?
        var summary: String?
        var firstUserMessage: String?
        var hasPlan = false

        var metadata: SessionMetadata {
            .init(
                title: explicitTitle ?? summary,
                titleIsExplicit: explicitTitle != nil,
                firstUserMessage: firstUserMessage,
                hasPlan: hasPlan
            )
        }
    }

    static func scan(
        file: DiscoveredSourceFile,
        from offset: Int64 = 0,
        through boundary: Int64,
        initialSessionID: String? = nil
    ) throws -> SessionMetadataScan {
        let fallbackSessionID = file.url.deletingPathExtension().lastPathComponent
        var currentSessionID = initialSessionID ?? fallbackSessionID
        if file.format == .geminiJSONL, offset > 0, initialSessionID == nil {
            currentSessionID = try GeminiJSONLSessionIdentity.id(before: offset, in: file.url)
                ?? currentSessionID
        }
        var accumulators: [String: Accumulator] = [:]

        func sessionID(in object: [String: Any]) -> String? {
            nonempty(object["sessionId"])
                ?? nonempty(object["session_id"])
                ?? nonempty(object["sessionID"])
        }

        func inspect(_ object: [String: Any], sessionID explicitSessionID: String? = nil) {
            let payload = object["payload"] as? [String: Any] ?? object
            if file.agent == .codex, object["type"] as? String == "session_meta" {
                currentSessionID = nonempty(payload["session_id"])
                    ?? nonempty(payload["id"])
                    ?? currentSessionID
            } else {
                currentSessionID = explicitSessionID ?? sessionID(in: object) ?? currentSessionID
            }
            let id = currentSessionID.isEmpty ? fallbackSessionID : currentSessionID
            var result = accumulators[id] ?? Accumulator()

            if file.agent == .claudeCode {
                if object["type"] as? String == "custom-title" {
                    result.explicitTitle = nonempty(object["customTitle"]) ?? result.explicitTitle
                } else if object["type"] as? String == "summary" {
                    result.summary = nonempty(object["summary"]) ?? result.summary
                }
            } else if file.agent == .gemini {
                result.explicitTitle = nonempty(object["title"]) ?? result.explicitTitle
                result.summary = nonempty(object["summary"]) ?? result.summary
            }

            let envelope = object["message"] as? [String: Any] ?? object
            let role: String?
            let content: Any?
            if file.agent == .codex {
                role = object["type"] as? String == "response_item" && payload["type"] as? String == "message"
                    ? payload["role"] as? String : (payload["type"] as? String == "agent_message" ? "assistant" : nil)
                content = payload["content"] ?? payload["text"] ?? payload["message"]
            } else {
                role = object["type"] as? String
                content = envelope["content"]
            }
            let prose = JSONHelpers.text(from: content)
            if role == "user", result.firstUserMessage == nil {
                result.firstUserMessage = userTitle(prose)
            }
            if ["assistant", "gemini"].contains(role ?? ""), containsPlan(prose) {
                result.hasPlan = true
            }
            let planContent = nonempty(payload["text"])
                ?? nonempty(payload["message"])
                ?? nonempty(JSONHelpers.text(from: payload["content"]))
            if file.agent == .codex, object["type"] as? String == "response_item",
               payload["type"] as? String == "plan", planContent != nil {
                result.hasPlan = true
            }

            // A submission must carry actual plan content; entering plan mode is insufficient.
            func submission(_ name: String?, _ args: Any?) {
                guard let name, ["exitplanmode", "exit_plan_mode"].contains(name.lowercased()) else { return }
                let input: [String: Any]?
                if let text = args as? String, let data = text.data(using: .utf8) {
                    input = try? JSONHelpers.object(from: data)
                } else {
                    input = args as? [String: Any]
                }
                if nonempty(input?["plan"]) != nil { result.hasPlan = true }
            }
            if file.agent == .codex, ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") {
                submission(payload["name"] as? String, payload["arguments"] ?? payload["input"])
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_use" {
                    submission(block["name"] as? String, block["input"])
                }
            }
            if file.agent == .gemini, object["type"] as? String != "user" {
                for call in object["toolCalls"] as? [[String: Any]] ?? [] {
                    submission(call["name"] as? String, call["args"])
                }
            }
            accumulators[id] = result
        }

        let checkpoint: Int64
        if file.format == .geminiJSON {
            let stream = GeminiSnapshotStream(file: file)
            var indexedSessionID: String?
            while let record = try stream.next() {
                try Task.checkCancellation()
                guard case .message(let message) = record,
                      let object = stream.currentMessageObject else { continue }
                indexedSessionID = message.sessionExternalID
                inspect(object, sessionID: message.sessionExternalID)
            }
            if let object = stream.rootObject {
                // Use the same identity that the streaming adapter assigned to message rows.
                inspect(object, sessionID: indexedSessionID ?? sessionID(in: object) ?? fallbackSessionID)
            }
            checkpoint = boundary
        } else {
            let cursor = try JSONLineCursor(url: file.url, from: offset, through: boundary)
            while let line = try cursor.next() {
                try Task.checkCancellation()
                guard let object = try? JSONHelpers.object(from: line.data) else { continue }
                let update = object["$set"] as? [String: Any]
                let rootSessionID = file.format == .geminiJSONL
                    ? GeminiJSONLSessionIdentity.explicitID(in: object)
                    : sessionID(in: object) ?? update.flatMap(sessionID(in:))
                inspect(object, sessionID: rootSessionID)
                if let update { inspect(update, sessionID: rootSessionID) }
                if file.agent == .gemini {
                    for range in JSONDocumentScanner.objectRanges(in: line.data, arrayKey: "messages") {
                        guard let message = try? JSONHelpers.object(from: line.data.subdata(in: range)) else { continue }
                        inspect(message, sessionID: file.format == .geminiJSONL ? currentSessionID : rootSessionID)
                    }
                }
            }
            checkpoint = cursor.checkpoint
        }

        return .init(
            sessions: accumulators.mapValues(\.metadata),
            checkpoint: checkpoint,
            finalSessionID: file.format == .geminiJSONL ? currentSessionID : nil
        )
    }

    static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func userTitle(_ prose: String) -> String? {
        var text = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("# AGENTS.md instructions for") { return nil }
        for tag in ["environment_context", "permissions instructions", "recommended_plugins", "instructions", "system-reminder"] {
            text = text.replacingOccurrences(of: "(?s)<\(tag)>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        // These wrappers carry the user's text rather than injected environment instructions.
        for tag in ["user_query", "user_instructions"] {
            text = text.replacingOccurrences(of: "<\(tag)>", with: "").replacingOccurrences(of: "</\(tag)>", with: "")
        }
        guard let value = nonempty(text) else { return nil }
        return JSONHelpers.normalizedPreview(value)
    }

    static func containsPlan(_ prose: String) -> Bool {
        prose.range(of: "(?s)<proposed_plan>\\s*\\S.*?</proposed_plan>", options: .regularExpression) != nil
    }
}

/// Source-specific sidecars are optional. Never open the agent's database for writing.
enum CodexSessionNamesLoadResult: Sendable {
    case loaded([String: String], complete: Bool, warning: String?)
    case absent
    case unavailable(String)
}

enum CodexSessionNames {
    static func load(directory: URL) throws -> CodexSessionNamesLoadResult {
        try Task.checkCancellation()
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            try Task.checkCancellation()
            let fileError = error as NSError
            let isMissing = (fileError.domain == NSCocoaErrorDomain
                && fileError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
                || (fileError.domain == NSPOSIXErrorDomain
                    && fileError.code == Int(ENOENT))
            if isMissing { return .absent }
            return .unavailable(error.localizedDescription)
        }
        let sessionIndex = directory.appendingPathComponent("session_index.jsonl")
        let hasSessionIndex = contents.contains {
            $0.standardizedFileURL.path == sessionIndex.standardizedFileURL.path
        }
        let databases = contents
            .filter {
                TraceFileIO.isCodexMetadataSidecar($0)
                    && $0.lastPathComponent != "session_index.jsonl"
            }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent, options: .numeric
                ) == .orderedDescending
            }
        guard hasSessionIndex || !databases.isEmpty else {
            try Task.checkCancellation()
            return .absent
        }

        var indexed: [String: (String, String)] = [:]
        if hasSessionIndex {
            do {
                let cursor = try JSONLineCursor(url: sessionIndex, from: 0)
                while let line = try cursor.next() {
                    try Task.checkCancellation()
                    guard let object = try? JSONHelpers.object(from: line.data),
                          let id = object["id"] as? String,
                          let name = SessionMetadataReader.nonempty(object["thread_name"])
                    else { continue }
                    let date = object["updated_at"] as? String ?? ""
                    if indexed[id] == nil || date >= indexed[id]!.1 {
                        indexed[id] = (name, date)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return .unavailable(error.localizedDescription)
            }
        }
        var names = indexed.mapValues { $0.0 }
        guard let newestDatabase = databases.first else {
            try Task.checkCancellation()
            return .loaded(names, complete: true, warning: nil)
        }

        try Task.checkCancellation()
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.2)
        do {
            let queue = try DatabaseQueue(path: newestDatabase.path, configuration: config)
            let rows = try queue.read { db in
                let columns = try db.columns(in: "threads").map(\.name)
                guard columns.contains("id") else {
                    throw SessionSourceError.malformedRecord(
                        "Codex metadata threads table has no id column"
                    )
                }
                let fields = ["id", "name", "title"]
                    .filter { columns.contains($0) }
                    .joined(separator: ", ")
                return try Row.fetchAll(db, sql: "SELECT \(fields) FROM threads")
            }
            for row in rows {
                try Task.checkCancellation()
                guard let id: String = row["id"] else { continue }
                let name: String? = row.hasColumn("name") ? row["name"] : nil
                let title: String? = row.hasColumn("title") ? row["title"] : nil
                names[id] = SessionMetadataReader.nonempty(name)
                    ?? names[id]
                    ?? SessionMetadataReader.nonempty(title)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if hasSessionIndex {
                return .loaded(
                    names, complete: false, warning: error.localizedDescription
                )
            }
            return .unavailable(error.localizedDescription)
        }
        try Task.checkCancellation()
        return .loaded(names, complete: true, warning: nil)
    }
}
