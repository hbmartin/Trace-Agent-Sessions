import Foundation

/// Preserve code characters while rendering inline prose for display and copy.
public enum TranscriptMarkdown {
    public static func render(_ source: String) -> AttributedString {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsed = try? AttributedString(markdown: protectingCode(in: normalized),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return parsed?.characters.isEmpty == false ? parsed! : AttributedString(normalized)
    }

    private static func protectingCode(in source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var codeLines = Set<Int>()
        var fence: (marker: Character, length: Int)?
        var needsBlockParser = false
        for (index, line) in lines.enumerated() {
            let candidate = fenceMarker(in: line)
            if let current = fence {
                codeLines.insert(index + 1)
                if let candidate, candidate.marker == current.marker,
                   candidate.length >= current.length,
                   candidate.tail.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                continue // Indentation inside a valid fence needs no additional parse.
            }
            if let candidate, candidate.marker != "`" || !candidate.tail.contains("`") {
                fence = (candidate.marker, candidate.length)
                codeLines.insert(index + 1)
            } else if mayContainContainerCode(line) {
                needsBlockParser = true
            }
        }
        if needsBlockParser, let blocks = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)) {
            // Block syntax is authoritative in ambiguous list/quote/indent contexts.
            codeLines.removeAll()
            for run in blocks.runs {
                guard let position = run.markdownSourcePosition,
                      run.presentationIntent?.components.contains(where: {
                          if case .codeBlock = $0.kind { return true }; return false
                      }) == true else { continue }
                codeLines.formUnion(position.startLine...position.endLine)
            }
        }
        let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        return lines.enumerated().map { index, line in
            guard codeLines.contains(index + 1) else { return String(line) }
            return line.map { escapable.contains($0) ? "\\\($0)" : String($0) }.joined()
        }.joined(separator: "\n")
    }

    private static func fenceMarker(in line: Substring)
        -> (marker: Character, length: Int, tail: Substring)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return nil }
        let text = line.dropFirst(spaces)
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let length = text.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length, text.dropFirst(length))
    }

    private static func mayContainContainerCode(_ line: Substring) -> Bool {
        var text = line
        var hasContainer = false
        while true {
            let spaces = text.prefix(while: { $0 == " " }).count
            let probe = text.dropFirst(min(spaces, 3))
            guard probe.first == ">" else { break }
            hasContainer = true
            text = probe.dropFirst()
            if text.first == " " { text = text.dropFirst() }
        }
        let probe = text.dropFirst(min(text.prefix(while: { $0 == " " }).count, 3))
        let markerLength: Int
        if let first = probe.first, "-*+".contains(first) { markerLength = 1 }
        else {
            let digits = probe.prefix(while: { $0.isNumber }).count
            let tail = probe.dropFirst(digits)
            markerLength = (1...9).contains(digits) && (tail.first == "." || tail.first == ")") ? digits + 1 : 0
        }
        if markerLength > 0 {
            let remainder = probe.dropFirst(markerLength)
            if remainder.first == " " || remainder.first == "\t" {
                hasContainer = true
                text = remainder.dropFirst()
            }
        }
        var columns = 0
        for character in text {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 4 - columns % 4 }
            else { break }
        }
        return columns >= 4 || (hasContainer && fenceMarker(in: text) != nil)
    }
}
