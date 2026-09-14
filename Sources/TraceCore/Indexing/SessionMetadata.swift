import Foundation
import GRDB

/// Derived metadata is disposable and can be backfilled without rewriting message rows.
struct SessionMetadata: Sendable {
    var title: String?
    var firstUserMessage: String?
    var hasPlan = false
}

enum SessionMetadataReader {
    static func scan(file: DiscoveredSourceFile, boundary: Int64) throws -> SessionMetadata {
        var result = SessionMetadata()
        var customTitle: String?
        var summary: String?
        func inspect(_ object: [String: Any]) {
            if file.agent == .claudeCode {
                if object["type"] as? String == "custom-title" {
                    customTitle = nonempty(object["customTitle"]) ?? customTitle
                } else if object["type"] as? String == "summary" {
                    summary = nonempty(object["summary"]) ?? summary
                }
            } else if file.agent == .gemini {
                customTitle = nonempty(object["title"]) ?? customTitle
                summary = nonempty(object["summary"]) ?? summary
            }
            let payload = object["payload"] as? [String: Any] ?? object
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
            let prose: String
            if let blocks = content as? [[String: Any]] {
                prose = blocks.filter { ["text", "input_text", "output_text"].contains($0["type"] as? String ?? "") }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { prose = content as? String ?? "" }
            if role == "user", result.firstUserMessage == nil { result.firstUserMessage = userTitle(prose) }
            if ["assistant", "gemini"].contains(role ?? ""), containsPlan(prose) { result.hasPlan = true }
            if file.agent == .codex, object["type"] as? String == "response_item",
               payload["type"] as? String == "plan", nonempty(payload["text"]) != nil {
                result.hasPlan = true
            }
            // A submission must carry actual plan content; entering plan mode is insufficient.
            func submission(_ name: String?, _ args: Any?) {
                guard let name, ["exitplanmode", "exit_plan_mode"].contains(name.lowercased()) else { return }
                let input: [String: Any]?
                if let text = args as? String, let data = text.data(using: .utf8) {
                    input = try? JSONHelpers.object(from: data)
                } else { input = args as? [String: Any] }
                if nonempty(input?["plan"]) != nil { result.hasPlan = true }
            }
            if file.agent == .codex, ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") {
                submission(payload["name"] as? String, payload["arguments"] ?? payload["input"])
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_use" {
                    submission(block["name"] as? String, block["input"])
                }
            }
            if file.agent == .gemini, object["type"] as? String != "user" {
                for call in object["toolCalls"] as? [[String: Any]] ?? [] {
                    submission(call["name"] as? String, call["args"])
                }
            }
        }
        if file.format == .geminiJSON {
            let object = try JSONHelpers.object(from: Data(contentsOf: file.url))
            inspect(object)
            for message in object["messages"] as? [[String: Any]] ?? [] { inspect(message) }
        } else {
            let cursor = try JSONLineCursor(url: file.url, from: 0)
            while let line = try cursor.next() {
                try Task.checkCancellation()
                guard line.offset + Int64(line.data.count) <= boundary else { break }
                guard let object = try? JSONHelpers.object(from: line.data) else { continue }
                inspect(object)
                if file.agent == .gemini {
                    for message in object["messages"] as? [[String: Any]] ?? [] { inspect(message) }
                }
            }
        }
        result.title = customTitle ?? summary
        return result
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
enum CodexSessionNames {
    static func load(directory: URL) -> [String: String] {
        var indexed: [String: (String, String)] = [:]
        if let cursor = try? JSONLineCursor(url: directory.appendingPathComponent("session_index.jsonl"), from: 0) {
            while let line = try? cursor.next() {
                guard let object = try? JSONHelpers.object(from: line.data), let id = object["id"] as? String,
                      let name = SessionMetadataReader.nonempty(object["thread_name"]) else { continue }
                let date = object["updated_at"] as? String ?? ""
                if indexed[id] == nil || date >= indexed[id]!.1 { indexed[id] = (name, date) }
            }
        }
        var names = indexed.mapValues { $0.0 }
        let databases = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for url in databases {
            var config = Configuration()
            config.readonly = true
            config.busyMode = .timeout(0.2)
            guard let queue = try? DatabaseQueue(path: url.path, configuration: config),
                  let rows = try? queue.read({ db in
                      let columns = try db.columns(in: "threads").map(\.name)
                      guard columns.contains("id") else { return [Row]() }
                      let fields = ["id", "name", "title"].filter { columns.contains($0) }.joined(separator: ", ")
                      return try Row.fetchAll(db, sql: "SELECT \(fields) FROM threads")
                  }) else { continue }
            for row in rows {
                guard let id: String = row["id"] else { continue }
                let name: String? = row.hasColumn("name") ? row["name"] : nil
                let title: String? = row.hasColumn("title") ? row["title"] : nil
                names[id] = SessionMetadataReader.nonempty(name) ?? names[id] ?? SessionMetadataReader.nonempty(title)
            }
            break
        }
        return names
    }
}
