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
        // Let Foundation's block parser distinguish list continuation paragraphs
        // from actual code, then preserve the original characters in our inline renderer.
        var codeLines = Set<Int>()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.contains(where: { $0.hasPrefix("    ") || $0.hasPrefix("\t") }),
           let blocks = try? AttributedString(markdown: source,
                options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)) {
            for run in blocks.runs {
                guard let position = run.markdownSourcePosition,
                      run.presentationIntent?.components.contains(where: {
                          if case .codeBlock = $0.kind { return true }
                          return false
                      }) == true else { continue }
                codeLines.formUnion(position.startLine...position.endLine)
            }
        }
        let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        return lines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard insideFence || isFence || codeLines.contains(index + 1) else { return String(line) }
            return line.map { escapable.contains($0) ? "\\\($0)" : String($0) }.joined()
        }.joined(separator: "\n")
    }
}
