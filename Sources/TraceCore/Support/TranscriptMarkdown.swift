import Foundation

/// Preserve code as literal text while rendering inline prose. Native text views
/// use the same characters for display and selection/copy.
public enum TranscriptMarkdown {
    public static func render(_ source: String) -> AttributedString {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsed = try? AttributedString(
            markdown: protectingCode(in: normalized),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed?.characters.isEmpty == false ? parsed! : AttributedString(normalized)
    }

    private static func protectingCode(in source: String) -> String {
        var fence: (marker: Character, length: Int)?
        var indentedBlock = false
        var previousLineWasBlank = true
        let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        return source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let blank = trimmed.isEmpty
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            let marker = trimmed.first
            let length = marker.map { first in trimmed.prefix(while: { $0 == first }).count } ?? 0
            let insideFence = fence != nil
            var isFence = false
            if let current = fence {
                if marker == current.marker, length >= current.length,
                   trimmed.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fence = nil
                    isFence = true
                }
            } else if let marker, (marker == "`" || marker == "~"), length >= 3,
                      marker != "`" || !trimmed.dropFirst(length).contains("`") {
                fence = (marker, length)
                isFence = true
            }
            if !blank { indentedBlock = indented && (indentedBlock || previousLineWasBlank) }
            previousLineWasBlank = blank
            guard insideFence || isFence || indentedBlock else { return String(line) }
            return line.map { escapable.contains($0) ? "\\\($0)" : String($0) }.joined()
        }.joined(separator: "\n")
    }
}
