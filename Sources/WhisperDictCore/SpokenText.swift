import Foundation

/// Releases complete sentences from a stream of text deltas so speech can
/// start on the first sentence while the rest is still arriving.
///
/// A sentence ends at `.`, `!` or `?` followed by whitespace, or at a line
/// break. A period after a single letter (`p.m.`, `e.g.`) or inside a number
/// (`3.5`) is not an ending. Whatever is left when the stream closes comes
/// out of `flush()`.
public struct SpokenSentenceSplitter: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let boundary = Self.firstBoundary(in: buffer) {
            let sentence = buffer[..<boundary.sentenceEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[boundary.remainderStart...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    public mutating func flush() -> String? {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }

    private struct Boundary {
        let sentenceEnd: String.Index
        let remainderStart: String.Index
    }

    // Group 1+2: terminal punctuation then whitespace. Group 3: a line break
    // run on its own, for lists and lines that never got a full stop.
    private static let pattern = try! NSRegularExpression(pattern: #"([.!?]+)(\s+)|(\n+)"#)

    private static func firstBoundary(in text: String) -> Boundary? {
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            if match.range(at: 3).location != NSNotFound {
                guard let run = Range(match.range(at: 3), in: text) else { continue }
                return Boundary(sentenceEnd: run.lowerBound, remainderStart: run.upperBound)
            }
            guard let punctuation = Range(match.range(at: 1), in: text),
                  let whitespace = Range(match.range(at: 2), in: text)
            else { continue }
            guard endsSentence(text, punctuation: punctuation) else { continue }
            return Boundary(sentenceEnd: punctuation.upperBound, remainderStart: whitespace.upperBound)
        }
        return nil
    }

    /// `!` and `?` always end a sentence. A period does unless the word before
    /// it is a single letter, which is an initial or an abbreviation.
    private static func endsSentence(_ text: String, punctuation: Range<String.Index>) -> Bool {
        if text[punctuation].contains(where: { $0 == "!" || $0 == "?" }) { return true }
        var wordLength = 0
        var index = punctuation.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            guard text[index].isLetter || text[index].isNumber else { break }
            wordLength += 1
        }
        return wordLength != 1
    }
}

/// Text as a voice should read it: markdown the model wrote for a screen
/// stripped back to the words.
public enum SpokenText {
    public static func plain(_ markdown: String) -> String {
        var text = markdown
        // Pictures are shown, never read: drop them before the link rule
        // would otherwise turn "![potato](url)" into a spoken "!potato".
        text = replace(text, #"!\[[^\]]*\]\(\s*<?[^)\s]+>?\s*\)"#, with: "")
        text = replace(text, #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#, with: "")
        text = replace(text, #"```[a-zA-Z]*\n?"#, with: "")
        text = replace(text, #"`([^`]+)`"#, with: "$1")
        text = replace(text, #"\[([^\]]+)\]\([^)]+\)"#, with: "$1")
        text = replace(text, #"https?://\S+"#, with: "")
        text = replace(text, #"(\*\*|__)(.+?)\1"#, with: "$2")
        text = replace(text, #"(?<![\w*])(\*|_)(\S(?:[^*_\n]*?\S)?)\1(?![\w*])"#, with: "$2")
        text = replace(text, #"(?m)^\s{0,3}#{1,6}\s+"#, with: "")
        text = replace(text, #"(?m)^\s*(?:[-*+•]|\d+[.)])\s+"#, with: "")
        return collapseWhitespace(text)
    }

    /// Runs of spaces become one space, runs of blank lines become one line
    /// break, and every line is trimmed.
    public static func collapseWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                replace(line, #"[ \t]+"#, with: " ").trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
