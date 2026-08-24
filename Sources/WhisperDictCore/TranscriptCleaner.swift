import Foundation

public struct TranscriptCleanupOptions: Equatable, Sendable {
    public var removeFillers: Bool
    public var autoPunctuate: Bool
    public var autoCapitalize: Bool

    public init(removeFillers: Bool, autoPunctuate: Bool, autoCapitalize: Bool) {
        self.removeFillers = removeFillers
        self.autoPunctuate = autoPunctuate
        self.autoCapitalize = autoCapitalize
    }

    public static let `default` = TranscriptCleanupOptions(
        removeFillers: true,
        autoPunctuate: true,
        autoCapitalize: true
    )
}

public enum TranscriptCleaner {
    public static func clean(_ text: String, options: TranscriptCleanupOptions = .default) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if options.removeFillers {
            result = replace(#"(?i)(?:^|(?<=[\s,.;!?]))(?:um+|uh+|ah+|er+|hmm+|mm+)(?=$|[\s,.;!?])\s*[,;]?\s*"#, in: result)
            result = replace(#"(?i),\s*(?:you know|i mean|sort of|kind of|basically|actually|literally|honestly)\s*[,;]?\s*"#, with: " ", in: result)
            result = replace(#"(?i)^(?:you know|i mean|sort of|kind of|basically|actually|literally|honestly)\s*[,;]?\s*"#, in: result)
            result = replace(#"(?i),\s*like\s*,\s*"#, with: " ", in: result)
            result = replace(#"(?i)^like\s*,\s*"#, in: result)
            result = replace(#"(?i)\b([\p{L}']+)\s+\1\b"#, with: "$1", in: result)
        }

        result = replace(#"\s+([,.;!?])"#, with: "$1", in: result)
        result = replace(#"([,;])(?=\S)"#, with: "$1 ", in: result)
        result = replace(#"\s+"#, with: " ", in: result)
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!.'\""))))

        if options.autoCapitalize, let firstLetter = result.firstIndex(where: { $0.isLetter }) {
            result.replaceSubrange(firstLetter...firstLetter, with: String(result[firstLetter]).uppercased())
        }
        if options.autoPunctuate, !result.isEmpty, result.last?.isPunctuation == false {
            result.append(".")
        }
        return result
    }

    private static func replace(_ pattern: String, with replacement: String = "", in value: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
