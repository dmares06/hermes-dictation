import Foundation

/// One entry in the suggestion strip above the keys.
public struct KeyboardSuggestion: Equatable, Sendable, Identifiable {
    /// What replaces the current word when tapped.
    public let text: String
    /// The word exactly as typed. Always offered so a correction can be
    /// refused — an autocorrect with no way back is worse than none.
    public let isLiteral: Bool
    /// Applied automatically when the next space or punctuation arrives.
    public let isAutocorrect: Bool

    public var id: String { "\(text)-\(isLiteral)" }

    public init(text: String, isLiteral: Bool = false, isAutocorrect: Bool = false) {
        self.text = text
        self.isLiteral = isLiteral
        self.isAutocorrect = isAutocorrect
    }
}

/// The spell-checking a keyboard needs, kept behind a protocol because the
/// system checker is UIKit-only and this module also builds for the tests.
public protocol WordChecking: Sendable {
    func isMisspelled(_ word: String) -> Bool
    func corrections(for word: String) -> [String]
    func completions(for partial: String) -> [String]
}

public enum KeyboardAutocorrect {
    /// Characters that belong to the word being typed. Apostrophes count so
    /// "don't" is one word and not a correction target twice over.
    private static let wordCharacters = CharacterSet.letters
        .union(CharacterSet(charactersIn: "'’"))

    /// Anything that ends a word and so triggers a pending autocorrect.
    public static func isWordTerminator(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return character == " " || character == "\n" || ".,!?;:".contains(character)
    }

    /// The partial word immediately before the cursor.
    public static func currentWord(before context: String?) -> String {
        guard let context else { return "" }
        let trailing = context.reversed().prefix { character in
            character.unicodeScalars.allSatisfy(wordCharacters.contains)
        }
        return String(trailing.reversed())
    }

    /// What to offer above the keys for the word being typed.
    ///
    /// The literal always comes first so the typed word stays one tap away,
    /// mirroring the system keyboard.
    public static func suggestions(for word: String, checker: some WordChecking) -> [KeyboardSuggestion] {
        guard word.count >= 2 else { return [] }

        let correction = autocorrection(for: word, checker: checker)
        var suggestions = [KeyboardSuggestion(text: word, isLiteral: true, isAutocorrect: false)]

        if let correction {
            suggestions.append(KeyboardSuggestion(text: correction, isAutocorrect: true))
        }

        let alreadyOffered = Set(suggestions.map { $0.text.lowercased() })
        let extras = (correction == nil ? checker.completions(for: word) : checker.corrections(for: word))
            .filter { !alreadyOffered.contains($0.lowercased()) }
            .prefix(correction == nil ? 2 : 1)
        suggestions.append(contentsOf: extras.map { KeyboardSuggestion(text: $0) })

        // A lone literal is not a suggestion, it is the word already on screen.
        return suggestions.count > 1 ? suggestions : []
    }

    /// The correction to apply silently on the next terminator, if any.
    ///
    /// Deliberately conservative: a keyboard that rewrites names, acronyms and
    /// deliberate spellings is worse than one that corrects nothing, and the
    /// user only notices the false positives.
    public static func autocorrection(for word: String, checker: some WordChecking) -> String? {
        guard word.count >= 2, isCorrectable(word), checker.isMisspelled(word) else { return nil }
        guard let candidate = checker.corrections(for: word).first else { return nil }
        guard candidate.lowercased() != word.lowercased() else { return nil }
        return matchingCapitalization(of: word, in: candidate)
    }

    /// The edit that swaps the typed word for `replacement`, optionally
    /// followed by the terminator that triggered it.
    public static func replacement(
        of word: String,
        with replacement: String,
        followedBy terminator: String = ""
    ) -> KeyboardTextEdit {
        KeyboardTextEdit(
            deleteBackwardCount: word.count,
            insertedText: replacement + terminator
        )
    }

    /// Words the checker may be confident about but the user meant literally:
    /// anything with a digit, an acronym, or a mid-word capital (a name, a
    /// brand, `iPhone`).
    private static func isCorrectable(_ word: String) -> Bool {
        guard !word.contains(where: \.isNumber) else { return false }
        let uppercase = word.filter(\.isUppercase).count
        guard uppercase <= 1 else { return false }
        if uppercase == 1, let first = word.first, !first.isUppercase { return false }
        return true
    }

    private static func matchingCapitalization(of word: String, in candidate: String) -> String {
        guard let typed = word.first, typed.isUppercase,
              let suggested = candidate.first, suggested.isLowercase
        else { return candidate }
        return suggested.uppercased() + candidate.dropFirst()
    }
}
