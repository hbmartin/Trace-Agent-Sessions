import Foundation
import GRDB

public enum FTSQueryParser {
    public static func parse(_ input: String) -> String? {
        var terms: [String] = []
        var current = ""
        var quoted = false
        var escaped = false

        func appendCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty, containsIndexedToken(trimmed) else { return }
            let safe = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
            terms.append(quoted ? "\"\(safe)\"" : "\"\(safe)\"*")
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

    // Ask the configured SQLite tokenizer rather than approximating its Unicode
    // 6.1 categories with the host's newer Unicode tables.
    private static let tokenDatabase: DatabaseQueue? = {
        guard let queue = try? DatabaseQueue() else { return nil }
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "CREATE VIRTUAL TABLE input USING fts5(text, tokenize='unicode61 remove_diacritics 2')")
                try db.execute(sql: "CREATE VIRTUAL TABLE tokens USING fts5vocab(input, 'row')")
            }
            return queue
        } catch { return nil }
    }()

    private static func containsIndexedToken(_ text: String) -> Bool {
        guard let tokenDatabase else { return true }
        return (try? tokenDatabase.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO input(rowid, text) VALUES (1, ?)", arguments: [text])
            defer { try? db.execute(sql: "DELETE FROM input WHERE rowid=1") }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tokens)") ?? false
        }) ?? true
    }

}
