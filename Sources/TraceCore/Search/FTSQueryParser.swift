import Foundation

public enum FTSQueryParser {
    public static func parse(_ input: String) -> String? {
        var terms: [String] = []
        var current = ""
        var quoted = false
        var escaped = false

        func appendCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let safe = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
            terms.append(quoted ? "\"\(safe)\"" : "\"\(safe)\"*")
            current = ""
        }

        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                if quoted {
                    appendCurrent()
                } else {
                    appendCurrent()
                }
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                appendCurrent()
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        appendCurrent()
        return terms.isEmpty ? nil : terms.joined(separator: " AND ")
    }
}
