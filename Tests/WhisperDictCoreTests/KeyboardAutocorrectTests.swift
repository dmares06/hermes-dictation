import XCTest
@testable import WhisperDictCore

/// A checker with a fixed opinion, so the tests exercise the policy rather
/// than whatever the system dictionary happens to contain.
private struct StubChecker: WordChecking {
    var misspelled: Set<String> = []
    var correctionsByWord: [String: [String]] = [:]
    var completionsByWord: [String: [String]] = [:]

    func isMisspelled(_ word: String) -> Bool { misspelled.contains(word.lowercased()) }
    func corrections(for word: String) -> [String] { correctionsByWord[word.lowercased()] ?? [] }
    func completions(for partial: String) -> [String] { completionsByWord[partial.lowercased()] ?? [] }
}

final class KeyboardAutocorrectTests: XCTestCase {
    private let checker = StubChecker(
        misspelled: ["teh", "hte", "recieve"],
        correctionsByWord: ["teh": ["the", "ten"], "hte": ["the"], "recieve": ["receive"]],
        completionsByWord: ["hel": ["hello", "help", "held"]]
    )

    // MARK: - Finding the word under the cursor

    func testCurrentWordIsTheTrailingRunOfLetters() {
        XCTAssertEqual(KeyboardAutocorrect.currentWord(before: "I think teh"), "teh")
        XCTAssertEqual(KeyboardAutocorrect.currentWord(before: "don't"), "don't")
        XCTAssertEqual(KeyboardAutocorrect.currentWord(before: "finished. "), "")
        XCTAssertEqual(KeyboardAutocorrect.currentWord(before: nil), "")
    }

    func testWordTerminatorsAreSpacesAndSentencePunctuation() {
        XCTAssertTrue(KeyboardAutocorrect.isWordTerminator(" "))
        XCTAssertTrue(KeyboardAutocorrect.isWordTerminator("."))
        XCTAssertTrue(KeyboardAutocorrect.isWordTerminator("!"))
        XCTAssertFalse(KeyboardAutocorrect.isWordTerminator("a"))
        XCTAssertFalse(KeyboardAutocorrect.isWordTerminator("ab"))
    }

    // MARK: - What gets corrected

    func testMisspelledWordsCorrectToTheTopCandidate() {
        XCTAssertEqual(KeyboardAutocorrect.autocorrection(for: "teh", checker: checker), "the")
        XCTAssertEqual(KeyboardAutocorrect.autocorrection(for: "recieve", checker: checker), "receive")
    }

    func testCorrectlySpelledWordsAreLeftAlone() {
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "hello", checker: checker))
    }

    func testCapitalizationOfTheTypedWordIsPreserved() {
        XCTAssertEqual(KeyboardAutocorrect.autocorrection(for: "Teh", checker: checker), "The")
    }

    func testNamesAcronymsAndWordsWithDigitsAreNeverRewritten() {
        let aggressive = StubChecker(
            misspelled: ["dmares", "api", "h2o", "iphone"],
            correctionsByWord: [
                "dmares": ["mares"], "api": ["apt"], "h2o": ["ho"], "iphone": ["phone"],
            ]
        )
        // Mid-word capitals and digits mean the user meant it literally.
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "API", checker: aggressive))
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "H2O", checker: aggressive))
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "iPhone", checker: aggressive))
        // A leading capital is ordinary sentence case, so it still corrects.
        XCTAssertEqual(KeyboardAutocorrect.autocorrection(for: "Dmares", checker: aggressive), "Mares")
    }

    func testSingleCharactersAreNeverCorrected() {
        let aggressive = StubChecker(misspelled: ["a"], correctionsByWord: ["a": ["I"]])
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "a", checker: aggressive))
    }

    func testACandidateEqualToTheTypedWordIsNotACorrection() {
        let noop = StubChecker(misspelled: ["teh"], correctionsByWord: ["teh": ["Teh"]])
        XCTAssertNil(KeyboardAutocorrect.autocorrection(for: "teh", checker: noop))
    }

    // MARK: - The suggestion strip

    func testTheTypedWordIsAlwaysOfferedFirstSoACorrectionCanBeRefused() {
        let suggestions = KeyboardAutocorrect.suggestions(for: "teh", checker: checker)
        XCTAssertEqual(suggestions.first?.text, "teh")
        XCTAssertTrue(suggestions.first?.isLiteral == true)
        XCTAssertEqual(suggestions.first(where: \.isAutocorrect)?.text, "the")
    }

    func testACorrectlySpelledWordOffersCompletions() {
        let suggestions = KeyboardAutocorrect.suggestions(for: "hel", checker: checker)
        XCTAssertEqual(suggestions.map(\.text), ["hel", "hello", "help"])
        XCTAssertFalse(suggestions.contains(where: \.isAutocorrect))
    }

    func testAWordWithNothingToOfferShowsNoStrip() {
        XCTAssertTrue(KeyboardAutocorrect.suggestions(for: "hello", checker: checker).isEmpty)
        XCTAssertTrue(KeyboardAutocorrect.suggestions(for: "h", checker: checker).isEmpty)
    }

    // MARK: - Applying it

    func testReplacementDeletesExactlyTheTypedWord() {
        XCTAssertEqual(
            KeyboardAutocorrect.replacement(of: "teh", with: "the", followedBy: " "),
            KeyboardTextEdit(deleteBackwardCount: 3, insertedText: "the ")
        )
        XCTAssertEqual(
            KeyboardAutocorrect.replacement(of: "teh", with: "the"),
            KeyboardTextEdit(deleteBackwardCount: 3, insertedText: "the")
        )
    }
}
