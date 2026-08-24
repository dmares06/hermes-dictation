import XCTest
@testable import WhisperDictCore

final class TranscriptCleanerTests: XCTestCase {
    func testRemovesHesitationsAndRepairsSpacing() {
        let result = TranscriptCleaner.clean(
            "  um, I uh need to, you know, send this today  ",
            options: .init(removeFillers: true, autoPunctuate: true, autoCapitalize: true)
        )

        XCTAssertEqual(result, "I need to send this today.")
    }

    func testPreservesLikeWhenItCarriesMeaning() {
        let result = TranscriptCleaner.clean(
            "i like pizza",
            options: .init(removeFillers: true, autoPunctuate: true, autoCapitalize: true)
        )

        XCTAssertEqual(result, "I like pizza.")
    }

    func testRemovesDelimitedDiscourseLike() {
        let result = TranscriptCleaner.clean(
            "It was, like, really helpful.",
            options: .init(removeFillers: true, autoPunctuate: true, autoCapitalize: true)
        )

        XCTAssertEqual(result, "It was really helpful.")
    }

    func testPreservesOptionsWhenCleanupFeaturesAreDisabled() {
        let result = TranscriptCleaner.clean(
            "um this stays",
            options: .init(removeFillers: false, autoPunctuate: false, autoCapitalize: false)
        )

        XCTAssertEqual(result, "um this stays")
    }

    func testCollapsesImmediateWordRepetitions() {
        let result = TranscriptCleaner.clean(
            "I I want to to send it",
            options: .init(removeFillers: true, autoPunctuate: true, autoCapitalize: true)
        )

        XCTAssertEqual(result, "I want to send it.")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(TranscriptCleaner.clean(" \n ", options: .default), "")
    }
}
