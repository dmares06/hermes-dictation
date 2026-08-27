import Foundation
import UIKit

/// `WordChecking` backed by the system dictionary.
///
/// `UITextChecker` is the same engine the stock keyboard uses, so corrections
/// match what the user already expects rather than a list of our own. One
/// instance is kept for the life of the keyboard: constructing a checker
/// loads the dictionary, which is far too slow to do per keystroke.
final class SystemWordChecker: WordChecking, @unchecked Sendable {
    private let checker = UITextChecker()
    private let language: String

    /// The keyboard's own language, falling back to whatever the checker
    /// supports if the user's locale has no dictionary.
    init(language: String? = nil) {
        let preferred = language ?? Locale.preferredLanguages.first ?? "en_US"
        self.language = UITextChecker.availableLanguages.contains(preferred)
            ? preferred
            : (UITextChecker.availableLanguages.first ?? "en_US")
    }

    func isMisspelled(_ word: String) -> Bool {
        let range = NSRange(location: 0, length: word.utf16.count)
        let misspelling = checker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        )
        return misspelling.location != NSNotFound
    }

    func corrections(for word: String) -> [String] {
        let range = NSRange(location: 0, length: word.utf16.count)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }

    func completions(for partial: String) -> [String] {
        let range = NSRange(location: 0, length: partial.utf16.count)
        return checker.completions(forPartialWordRange: range, in: partial, language: language) ?? []
    }
}
