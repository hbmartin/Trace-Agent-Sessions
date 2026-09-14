import Foundation

enum JSONHelpers {
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionSourceError.malformedRecord("expected an object")
        }
        return object
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func timestampMilliseconds(_ value: Any?, fallback: Int64) -> Int64 {
        if let numeric = int64(value) {
            return numeric > 10_000_000_000 ? numeric : numeric * 1_000
        }
        guard let string = value as? String else { return fallback }
        if let date = ISO8601DateFormatter.traceWithFractional.date(from: string)
            ?? ISO8601DateFormatter.traceBasic.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        return fallback
    }

    static func compactJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func text(from content: Any?) -> String {
        if let string = content as? String { return string }
        guard let array = content as? [Any] else { return "" }
        return array.compactMap { item in
            if let string = item as? String { return string }
            guard let object = item as? [String: Any] else { return nil }
            return object["text"] as? String
                ?? object["content"] as? String
                ?? object["output"] as? String
        }.joined(separator: "\n")
    }

    static func normalizedPreview(_ text: String, limit: Int = 160) -> String {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let traceWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let traceBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
